FROM alpine:3.24.3

RUN apk add --no-cache openssh rrsync tini shadow

ENV BACKUP_USERNAME=backupuser \
    PUID=1000 \
    PGID=1000 \
    ALLOW_SOURCE_DELETE=false

COPY entrypoint.sh /entrypoint.sh
COPY source-command.py /usr/local/bin/rsync-source-command

RUN mkdir -p /run/sshd /data \
    && chmod 755 /entrypoint.sh /usr/local/bin/rsync-source-command

EXPOSE 22

VOLUME ["/data"]

ENTRYPOINT ["/sbin/tini", "--"]

CMD ["/entrypoint.sh"]
