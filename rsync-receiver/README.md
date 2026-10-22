# rsync-receiver

Receives rsync uploads over SSH. The login account is restricted to writing to `/data`, with no interactive shell, file downloads, or SSH forwarding.

## Pull

```sh
docker pull henry42/rsync-receiver:latest
```

To pin a release, replace `latest` with a published version tag in both the pull and run commands.

## Runtime configuration

| Environment variable | Default | Description |
| --- | --- | --- |
| `SSH_HOST_KEYS_B64` | Required | SSH server host private keys. Provide one complete Base64-encoded private key per line; multiple keys are supported. |
| `BACKUP_USERNAME` | `backupuser` | SSH login username. The account is created at startup. |
| `PUB_KEY` | Required | Authorized client OpenSSH public keys, one per line, without `authorized_keys` options. |
| `NO_OVERWRITE` | `false` | When `true`, skips files that already exist at the destination. |
| `NO_DEL` | `false` | When `true`, rejects client `--delete*` and `--remove*` options. |

Both flags accept only lowercase `true` or `false`; other values cause startup to fail. The flags operate independently. By default, clients can update existing files and request deletions; the server does not perform cleanup on its own.

Usernames must be at most 32 characters long and contain only lowercase letters, digits, underscores, or hyphens. The first character must be a lowercase letter or underscore. Existing system accounts in the image cannot be reused.

## Run

Generate host private keys for two algorithms on the Docker host once, then reuse the same files when recreating the container. Store these files securely. The private keys must have no passphrase.

```sh
mkdir -p hostkeys
chmod 700 hostkeys
ssh-keygen -t ed25519 -N '' -f hostkeys/ssh_host_ed25519_key
ssh-keygen -t rsa -b 3072 -N '' -f hostkeys/ssh_host_rsa_key

# Encode each private key as a single line, separating the keys with a newline.
SSH_HOST_KEYS_B64="$(
  base64 < hostkeys/ssh_host_ed25519_key | tr -d '\n'
  printf '\n'
  base64 < hostkeys/ssh_host_rsa_key | tr -d '\n'
)"
export SSH_HOST_KEYS_B64
PUB_KEY="$(cat "$HOME/.ssh/id_ed25519.pub")"
export PUB_KEY

docker run -d --name rsync-receiver \
  -p 2222:22 \
  -v backup-data:/data \
  -e SSH_HOST_KEYS_B64 \
  -e PUB_KEY \
  -e BACKUP_USERNAME=archive \
  -e NO_OVERWRITE=false \
  -e NO_DEL=false \
  henry42/rsync-receiver:latest

unset SSH_HOST_KEYS_B64 PUB_KEY
```

## Upload files

Run this command on the client, replacing `server` with the Docker host's address. The destination maps to `/data` inside the container:

```sh
rsync -av -e 'ssh -p 2222' ./source/ archive@server:.
```

The client must use the private key corresponding to a public key in `PUB_KEY`.

## SSH keys

Host private keys identify the server, while `PUB_KEY` contains the client public keys allowed to log in. Keep the same host keys for the lifetime of a service. Multiple host keys can provide different algorithms; SSH negotiates which one to use.

Invalid keys or configuration cause the container to stop during startup. Base64 is only an encoding; anyone with Docker management access can still inspect the environment variables.

## Storage

The example stores backups in the Docker volume `backup-data`, mounted at `/data`. Reuse this volume when recreating the container to retain your backups.

At startup, the top-level `/data` directory is assigned to the login account and given permissions of `700`. Existing files are not modified recursively. When bind-mounting a host directory, use a dedicated directory and ensure its existing contents are accessible to the account's UID/GID.

`NO_OVERWRITE=true` works well when each upload uses a separate dated directory: files already present at the same path are skipped. `NO_DEL=true` restricts rrsync options; it does not provide immutable storage. Use snapshots or other storage policies when historical versions need protection.

References: [OpenSSH host private keys](https://man.openbsd.org/sshd#h), [rrsync options](https://download.samba.org/pub/rsync/rrsync.1.html).
