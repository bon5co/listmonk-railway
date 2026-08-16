# listmonk on Railway

Wrapper image for the [Listmonk](https://listmonk.app) Railway template
(`listmonk-...` on the Railway marketplace), pinned to listmonk **v6.2.0**.

Upstream's image is used as-is; this repo only adds the boot work a Railway
deployment needs and that listmonk offers no configuration path for.

## What the entrypoint does

1. **Seeds a real dashboard super admin, and refuses to boot without a password.**
   With `LISTMONK_ADMIN_USER` / `LISTMONK_ADMIN_PASSWORD` unset, `listmonk --install`
   logs `no superadmin user created. Visit webpage to create user.` and the login
   page becomes a first-time-setup form that any visitor can submit — the first
   stranger to open the URL gets the Super Admin role.
2. **Re-applies that password on every boot**, so a redeploy is a working password
   reset. listmonk has no CLI flag and no HTTP route for this; the password is a
   pgcrypto `CRYPT(..., GEN_SALT('bf'))` value in Postgres (`queries/users.sql`).
3. **Sets `app.root_url` to the deployment's own domain.** It is a database
   setting, not a config key, so no environment variable reaches it, and it
   defaults to `http://localhost:9000` — the address every unsubscribe link,
   tracking pixel, archive link and password-reset mail is built from.
4. **Writes the deployer's SMTP account into the settings row** when `SMTP_HOST`
   is supplied, and disables listmonk's stock `smtp.yoursite.com` entry when it
   is not.
5. **Runs nginx in front with a login rate limit**, keyed on the first address in
   `X-Forwarded-For` (Railway's edge appends a hop that rotates between
   requests). listmonk contains no login throttle of any kind.

## Variables

| Variable | Required | Notes |
|---|---|---|
| `LISTMONK_ADMIN_USER` | no | defaults to `admin`, min 3 chars |
| `LISTMONK_ADMIN_PASSWORD` | **yes** | min 8 chars; boot fails if empty |
| `LISTMONK_ADMIN_EMAIL` | no | address on the seeded account |
| `LISTMONK_db__*` | yes | host, port, user, password, database, ssl_mode |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` | no | written into settings on boot |
| `SMTP_AUTH_PROTOCOL` / `SMTP_TLS_TYPE` / `SMTP_FROM_EMAIL` | no | `login` / `STARTTLS` by default |
| `PORT` | injected | nginx binds it; listmonk stays on `127.0.0.1:9000` |

The uploads directory (`/listmonk/uploads`) must be on a volume.
