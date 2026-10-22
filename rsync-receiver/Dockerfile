FROM alpine:3.22.2

RUN apk add --no-cache openssh rrsync tini shadow

ENV BACKUP_USERNAME=backupuser \
    NO_OVERWRITE=false \
    NO_DEL=false

COPY entrypoint.sh /entrypoint.sh

RUN mkdir -p /run/sshd /data && chmod 755 /entrypoint.sh

EXPOSE 22

VOLUME ["/data"]

ENTRYPOINT ["/sbin/tini", "--"]

CMD ["/entrypoint.sh"]
