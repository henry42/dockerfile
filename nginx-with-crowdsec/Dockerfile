FROM nginx:1.29.4-alpine

ADD crowdsec-nginx-bouncer-v1.1.5-rc1.tar.xz /tmp
COPY install.sh /tmp/crowdsec-nginx-bouncer-v1.1.5-rc1
RUN cd /tmp/crowdsec-nginx-bouncer-v1.1.5-rc1 && apk update && ./install.sh -y

COPY 50-crowdsec-setup.sh /docker-entrypoint.d