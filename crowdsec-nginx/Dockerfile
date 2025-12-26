FROM alpine:3.23.2

ADD crowdsec-nginx-bouncer-v1.1.5-rc1.tar.xz /tmp

COPY install.sh /tmp/crowdsec-nginx-bouncer-v1.1.5-rc1

RUN cd /tmp/crowdsec-nginx-bouncer-v1.1.5-rc1 \
    && ./install.sh -y \
    && rm -rf /tmp/* \
        /var/cache/apk/* \
        /root/.cache/* \
        /usr/include/* \
        /usr/share/man/* \
        /usr/share/doc/*

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]