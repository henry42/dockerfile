FROM alpine:3.23.2

ADD crowdsec-nginx-bouncer-v1.1.5-rc1.tar.xz /tmp

COPY install.sh /tmp/crowdsec-nginx-bouncer-v1.1.5-rc1

RUN cd /tmp/crowdsec-nginx-bouncer-v1.1.5-rc1 && apk update && ./install.sh -y

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

CMD ["nginx", "-g", "daemon off;"]