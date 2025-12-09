FROM alpine:3.22.2

RUN apk add --no-cache openssh rrsync tini shadow

RUN mkdir -p /var/run/sshd && \
    sed -i 's/#PasswordAuthentication .*$/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication .*$/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#LogLevel .*$/LogLevel VERBOSE/' /etc/ssh/sshd_config && \
    sed -i 's/#PrintMotd .*$/PrintMotd no/' /etc/ssh/sshd_config

RUN ssh-keygen -A

RUN adduser -D -s /bin/sh backupuser && usermod -p '*' backupuser

RUN mkdir -p /home/backupuser/.ssh && \
    chown -R backupuser:backupuser /home/backupuser/.ssh && \
    chmod 700 /home/backupuser/.ssh && \
    touch /home/backupuser/.ssh/authorized_keys && chmod 600 /home/backupuser/.ssh/authorized_keys && \
    chown -R backupuser:backupuser /home/backupuser/.ssh

RUN mkdir -p /data    


RUN echo -e "#!/bin/sh \n\
set -e \n\
if [ -z \"\$PUB_KEY\" ]; then \n\
  echo \"Error: PUB_KEY environment variable is empty. Container stopped.\" \n\
  exit 1 \n\
fi \n\
\n\
echo \"command=\\\"/usr/bin/rrsync -no-lock -no-overwrite -wo /data\\\",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding \$PUB_KEY\" > /home/backupuser/.ssh/authorized_keys \n\
\n\
chown backupuser:backupuser /data && chmod 300 /data \n\
echo \"Service Started. Ready for backup.\" \n\
exec /usr/sbin/sshd -D -e \n\
\n\
"> /entrypoint.sh

RUN chmod a+x /entrypoint.sh

EXPOSE 22

VOLUME ["/data"]

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]

