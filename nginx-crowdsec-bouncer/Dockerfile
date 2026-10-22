FROM alpine:3.24.3

ADD crowdsec-nginx-bouncer-v1.2.3.tgz /tmp/

COPY install.sh /tmp/crowdsec-nginx-bouncer-v1.2.3/install.sh

RUN set -eu; \
    chmod 0755 /tmp/crowdsec-nginx-bouncer-v1.2.3/install.sh; \
    cd /tmp/crowdsec-nginx-bouncer-v1.2.3; \
    ./install.sh -y; \
    cd /; \
    rm -rf /tmp/crowdsec-nginx-bouncer-v1.2.3 /root/.cache/luarocks; \
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log; \
    nginx -t

COPY entrypoint.sh /entrypoint.sh

RUN chmod 0755 /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

CMD ["nginx", "-g", "daemon off;"]
