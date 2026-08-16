FROM listmonk/listmonk:v6.2.0

# postgresql-client: seed the super admin password and the settings rows that
#   listmonk keeps in the database rather than in its config file.
# nginx: listmonk ships no login throttle of any kind, so the rate limit has to
#   live in front of it.
# gettext: envsubst, for templating the generated nginx config.
USER root
RUN apk add --no-cache postgresql-client nginx gettext

# listmonk itself only ever listens on loopback; nginx owns the public port.
ENV LISTMONK_app__address="127.0.0.1:9000"

COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY proxy_common.conf /etc/nginx/proxy_common.conf
COPY --chmod=755 railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
