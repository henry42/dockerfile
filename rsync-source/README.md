# rsync-source

Provides files for rsync clients to pull over SSH. The login account is restricted to rsync downloads from `/data`, with no uploads, interactive shell, or SSH forwarding. Removing successfully copied source files is disabled by default and can be enabled explicitly.

## Pull

```sh
docker pull henry42/rsync-source:latest
```

To pin a release, replace `latest` with a published version tag in both the pull and run commands.

## Runtime configuration

| Environment variable | Default | Description |
| --- | --- | --- |
| `SSH_HOST_KEYS_B64` | Generated automatically | Optional SSH server host private keys. Provide one complete Base64-encoded private key per line. When unset or empty, an Ed25519 host key is generated and its Base64 value is printed in the container logs. |
| `BACKUP_USERNAME` | `backupuser` | SSH login username. The account is created at startup. |
| `PUID` | `1000` | UID of the login account. Match a host UID that can read the source files. Must be between `1000` and `2147483647`. |
| `PGID` | `1000` | Primary GID of the login account. Match a host group that can access the source files. Must be between `1` and `2147483647`. |
| `PUB_KEY` | Required | Authorized client OpenSSH public keys, one per line, without `authorized_keys` options. |
| `ALLOW_SOURCE_DELETE` | `false` | When `true`, permits clients to request removal of successfully copied source files using `--remove-source-files`. It does not delete files automatically or permit uploads. |

`ALLOW_SOURCE_DELETE` accepts only lowercase `true` or `false`. UID and GID values must be decimal integers without leading zeros. Invalid configuration causes startup to fail.

Usernames must be at most 32 characters long and contain only lowercase letters, digits, underscores, or hyphens. The first character must be a lowercase letter or underscore. Existing system accounts cannot be reused, and `PUID` must not belong to another account in the container. Recreate the container to change `PUID` or `PGID`.

## Run

Set `PUB_KEY` to the pulling client's public key. Run the container on the host whose files you want to expose. Replace `/srv/source` with an existing directory and set `PUID` and `PGID` to values that can access it.

```sh
PUB_KEY="$(cat "$HOME/.ssh/id_ed25519.pub")"
export PUB_KEY

docker run -d --name rsync-source \
  -p 2222:22 \
  --mount type=bind,src=/srv/source,dst=/data,readonly \
  -e PUB_KEY \
  -e BACKUP_USERNAME=backupuser \
  -e PUID=1000 \
  -e PGID=1000 \
  henry42/rsync-source:latest

unset PUB_KEY
```

The container does not change the ownership or permissions of `/data` or its contents. The login account needs read permission on files and read/search permission on directories it will traverse. Supplementary host group memberships are not inherited; use `PGID` or grant the required permissions on the host.

## Download files

Run this on the client, replacing `server` with the Docker host's address:

```sh
rsync -av -e 'ssh -p 2222' backupuser@server:. ./backup/
```

The remote `:.` maps to the contents of `/data/` inside the container. To download a subdirectory, use a path such as `backupuser@server:./documents/`. The client must use the private key corresponding to a public key in `PUB_KEY`.

To remove files from the **local destination** when they no longer exist on the server, add `--delete`:

```sh
rsync -av --delete -e 'ssh -p 2222' backupuser@server:. ./backup/
```

This works with the default read-only source policy. Use `--dry-run --itemize-changes` to preview changes before applying deletions.

## Remove copied source files

To allow removal of files from the **server**, recreate the container with `-e ALLOW_SOURCE_DELETE=true` and a writable data mount:

```sh
docker run -d --name rsync-source \
  -p 2222:22 \
  --mount type=bind,src=/srv/source,dst=/data \
  -e PUB_KEY \
  -e BACKUP_USERNAME=backupuser \
  -e PUID=1000 \
  -e PGID=1000 \
  -e ALLOW_SOURCE_DELETE=true \
  henry42/rsync-source:latest
```

Set `PUB_KEY` again as in the first example, and remove the old container before reusing its name. The login account also needs write/search permission on the directories containing files to remove; host permissions and sticky-bit rules still apply.

The client must then request source removal explicitly:

```sh
rsync -av --remove-source-files -e 'ssh -p 2222' \
  backupuser@server:. ./backup/
```

Only successfully copied source files are removed; source directories remain. Use this for completed files that are no longer being written. With `ALLOW_SOURCE_DELETE=false`, source-removal requests are rejected, even if `/data` was mounted writable.

Enabling source deletion does not permit uploads, arbitrary SSH commands, or server-side log/batch output. A read-only data mount prevents source deletion regardless of this setting.

## SSH keys

Host private keys identify the server. `PUB_KEY` contains the client public keys allowed to log in; multiple clients can be authorized by providing one key per line.

When `SSH_HOST_KEYS_B64` is unset or empty, the container generates an Ed25519 host key and reuses it on subsequent restarts of the same container. After startup validation succeeds, the container prints a warning and a reusable value:

```text
SSH_HOST_KEYS_B64=<base64-encoded-private-host-key>
```

View it with `docker logs rsync-source`. This is a **private server host key**: keep the logs private and save the value securely. When replacing the container, export `SSH_HOST_KEYS_B64` with the saved value and add `-e SSH_HOST_KEYS_B64` to the run command to retain the same SSH fingerprint. The source mount does not store this key.

You may instead supply your own unencrypted host private keys. Each line must contain one complete, unwrapped Base64-encoded private key. Use different key algorithms when providing multiple host keys. Supplied keys are validated and are not printed in the logs; invalid supplied keys cause startup to fail.

Base64 is only an encoding. Anyone with Docker management access can inspect container environment variables.

## SSH logs and CrowdSec

OpenSSH runs with `LogLevel VERBOSE` and `sshd -D -e`. Connection, authentication, and disconnect events are written to stderr and collected by Docker. View them on the Docker host:

```sh
docker logs --tail 100 -f rsync-source
```

These events are not automatically written to the host's `/var/log/auth.log`. Their retention follows the container's Docker logging configuration.

CrowdSec running on the host can read the container logs through the Docker API. It needs access to the Docker socket, which defaults to `/var/run/docker.sock`. Save the following acquisition configuration as `/etc/crowdsec/acquis.d/rsync.yaml` on that host:

```yaml
source: docker
container_name:
  - rsync-source
follow_stdout: false
follow_stderr: true
labels:
  type: sshd
```

Use your actual container name. To monitor both images, list both container names under `container_name` in the same acquisition configuration and avoid configuring the same container twice.

The `sshd` label identifies raw SSH log messages rather than host syslog records. Only stderr is collected: startup messages, including any automatically generated private host key printed to stdout, are excluded from this acquisition.

Install the SSH collection and raw log parser, then restart CrowdSec. On a host using systemd:

```sh
sudo cscli collections install crowdsecurity/sshd
sudo cscli parsers install crowdsecurity/syslog-logs
sudo systemctl restart crowdsec
```

The `syslog-logs` package also includes the non-syslog parser used for raw `sshd` messages. After making an SSH connection attempt, run `sudo cscli metrics` to check the acquisition and parser counters.

Detection and blocking are configured separately. To block SSH connections, use a host firewall bouncer; an Nginx bouncer protects HTTP traffic. With Docker's iptables backend, configure the firewall bouncer to cover `DOCKER-USER` as well as host traffic. See [CrowdSec Docker acquisition](https://docs.crowdsec.net/docs/log_processor/data_sources/docker/) and [firewall bouncer configuration](https://docs.crowdsec.net/u/bouncers/firewall/#iptables_chains).

References: [OpenSSH logging](https://man.openbsd.org/sshd#e), [rrsync](https://download.samba.org/pub/rsync/rrsync.1.html), [rsync source removal and deletion options](https://download.samba.org/pub/rsync/rsync.1).
