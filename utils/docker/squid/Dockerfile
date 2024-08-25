FROM alpine:3.8

RUN set -ex; \
    apk add squid; \
    install -Dd -o squid -g squid -m 755 /var/lib/squid; \
    su squid -s /bin/sh -c '/usr/lib/squid/ssl_crtd -c -s /var/lib/squid/ssl_db'

CMD ["/bin/sh", "-c", "/usr/sbin/crond; /usr/sbin/squid -N"]
