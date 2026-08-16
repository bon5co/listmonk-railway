#!/bin/sh
# Railway entrypoint for listmonk.
#
# What this does that a stock listmonk deploy does not:
#   1. Refuses to boot without an admin password, and seeds a real dashboard
#      super admin through listmonk's own --install path. Without
#      LISTMONK_ADMIN_USER/LISTMONK_ADMIN_PASSWORD, `--install` prints
#      "no superadmin user created. Visit webpage to create user." and the login
#      page turns into a first-time-setup form that any visitor can submit.
#   2. Re-applies that password on every boot, so a redeploy is a working
#      password reset. listmonk exposes no CLI or HTTP path for this.
#   3. Points app.root_url at the deployment's own domain. It is a database
#      setting, not a config key, so it cannot be set by environment variable and
#      defaults to http://localhost:9000 -- the address every unsubscribe link,
#      tracking pixel, archive link and password-reset mail is built from.
#   4. Writes the deployer's SMTP account into the settings row when one is
#      supplied, and disables listmonk's dummy smtp.yoursite.com entry when it is
#      not, so a fresh instance does not queue mail at a host that does not exist.
#   5. Runs nginx in front, because listmonk has no login rate limiting.
set -eu

log() { echo "[railway] $*"; }
die() { echo "[railway] FATAL: $*" >&2; exit 1; }

ADMIN_USER="${LISTMONK_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${LISTMONK_ADMIN_PASSWORD:-}"

[ -n "$ADMIN_PASSWORD" ] || die "LISTMONK_ADMIN_PASSWORD is empty. Refusing to boot: with no admin password listmonk creates no user and its login page becomes an open first-time-setup form."
[ "${#ADMIN_PASSWORD}" -ge 8 ] || die "LISTMONK_ADMIN_PASSWORD must be at least 8 characters (listmonk's own minimum)."
[ "${#ADMIN_USER}" -ge 3 ] || die "LISTMONK_ADMIN_USER must be at least 3 characters (listmonk's own minimum)."
export LISTMONK_ADMIN_USER="$ADMIN_USER"
export LISTMONK_ADMIN_PASSWORD="$ADMIN_PASSWORD"

DB_HOST="${LISTMONK_db__host:-localhost}"
DB_PORT="${LISTMONK_db__port:-5432}"
DB_USER="${LISTMONK_db__user:-listmonk}"
DB_NAME="${LISTMONK_db__database:-listmonk}"
DB_PASSWORD="${LISTMONK_db__password:-}"
DB_SSLMODE="${LISTMONK_db__ssl_mode:-disable}"

log "waiting for postgres at ${DB_HOST}:${DB_PORT}"
i=0
while ! nc -z "$DB_HOST" "$DB_PORT" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || die "postgres at ${DB_HOST}:${DB_PORT} did not accept connections within 150s"
    sleep 0.5
done
log "postgres is reachable"

psql_run() {
    PGPASSWORD="$DB_PASSWORD" psql \
        --host="$DB_HOST" --port="$DB_PORT" --username="$DB_USER" --dbname="$DB_NAME" \
        --no-psqlrc --quiet --tuples-only --no-align \
        -v ON_ERROR_STOP=1 "$@"
}
export PGSSLMODE="$DB_SSLMODE"

# --- 1. schema install / upgrade, and the super admin ------------------------
# --idempotent makes --install a no-op once the schema exists; --upgrade applies
# any pending migrations for the pinned version.
log "running install (idempotent) and upgrade"
./listmonk --install --idempotent --upgrade --yes

# --- 2. password rotation ----------------------------------------------------
# listmonk hashes passwords in Postgres with pgcrypto (queries/users.sql:32:
# CRYPT($4, GEN_SALT('bf'))), so the same expression is the whole reset path.
# On the first boot --install has already created this user; on later boots this
# is what makes a redeploy an actual password reset.
log "re-applying the admin password for '${ADMIN_USER}'"
ROTATED=$(psql_run <<SQL
INSERT INTO users (username, password_login, password, email, name, type, user_role_id, status)
VALUES (
    '${ADMIN_USER}',
    TRUE,
    CRYPT(\$\$${ADMIN_PASSWORD}\$\$, GEN_SALT('bf')),
    '${LISTMONK_ADMIN_EMAIL:-admin@localhost}',
    '${ADMIN_USER}',
    'user',
    1,
    'enabled'
)
ON CONFLICT (username) DO UPDATE SET
    password       = CRYPT(\$\$${ADMIN_PASSWORD}\$\$, GEN_SALT('bf')),
    password_login = TRUE,
    status         = 'enabled',
    updated_at     = NOW()
RETURNING id;
SQL
)
[ -n "$ROTATED" ] || die "could not seed or update the admin user"
log "admin user id=${ROTATED} ready"

# --- 3. root_url -------------------------------------------------------------
# Only claim it while it is still the stock default or a Railway domain, so a
# deployer who switches to a custom domain in the UI keeps their value.
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    log "setting app.root_url to https://${RAILWAY_PUBLIC_DOMAIN} (was the stock http://localhost:9000)"
    psql_run >/dev/null <<SQL
UPDATE settings
   SET value = to_jsonb('https://${RAILWAY_PUBLIC_DOMAIN}'::text), updated_at = NOW()
 WHERE key = 'app.root_url'
   AND (value #>> '{}' = 'http://localhost:9000'
        OR value #>> '{}' LIKE '%.up.railway.app'
        OR value #>> '{}' LIKE 'https://${RAILWAY_PUBLIC_DOMAIN}');
SQL
fi

# --- 4. SMTP -----------------------------------------------------------------
# listmonk keeps SMTP in the settings row, not in the environment, so a template
# cannot hand it over as a variable without writing it here. Stock ships one
# enabled entry pointing at smtp.yoursite.com with CRAM auth.
if [ -n "${SMTP_HOST:-}" ]; then
    log "writing the supplied SMTP account into settings (host=${SMTP_HOST})"
    psql_run >/dev/null <<SQL
UPDATE settings
   SET value = jsonb_build_array(
           jsonb_build_object(
               'enabled', true,
               'host', '${SMTP_HOST}',
               'port', ${SMTP_PORT:-587}::int,
               'auth_protocol', '${SMTP_AUTH_PROTOCOL:-login}',
               'username', '${SMTP_USERNAME:-}',
               'password', '${SMTP_PASSWORD:-}',
               'hello_hostname', '',
               'max_conns', 10,
               'idle_timeout', '15s',
               'wait_timeout', '5s',
               'max_msg_retries', 2,
               'msg_retry_delay', '10ms',
               'tls_type', '${SMTP_TLS_TYPE:-STARTTLS}',
               'tls_skip_verify', false,
               'email_headers', '[]'::jsonb,
               'from_addresses', '[]'::jsonb
           )
       ),
       updated_at = NOW()
 WHERE key = 'smtp';
SQL
    if [ -n "${SMTP_FROM_EMAIL:-}" ]; then
        psql_run >/dev/null <<SQL
UPDATE settings
   SET value = to_jsonb('${SMTP_FROM_EMAIL}'::text), updated_at = NOW()
 WHERE key = 'app.from_email';
SQL
    fi
else
    # Disable the dummy entries rather than leave a deploy queueing mail at a
    # host that does not resolve. The deployer turns SMTP on in Settings -> SMTP.
    log "no SMTP_HOST supplied; disabling the stock smtp.yoursite.com entry"
    psql_run >/dev/null <<SQL
UPDATE settings
   SET value = (
           SELECT jsonb_agg(jsonb_set(entry, '{enabled}', 'false'::jsonb))
             FROM jsonb_array_elements(value) AS entry
       ),
       updated_at = NOW()
 WHERE key = 'smtp'
   AND value @> '[{"host": "smtp.yoursite.com"}]';
SQL
fi

# --- 5. nginx ----------------------------------------------------------------
# Railway injects PORT into every service and the healthcheck dials that injected
# port, so nginx must take it and listmonk must stay on loopback.
export NGINX_PORT="${PORT:-8080}"
export LISTMONK_app__address="127.0.0.1:9000"
mkdir -p /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi
envsubst '${NGINX_PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
nginx -t
log "starting nginx on :${NGINX_PORT}, listmonk on 127.0.0.1:9000"
nginx

exec ./listmonk "$@"
