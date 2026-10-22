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
| `SSH_HOST_KEYS_B64` | Generated automatically | Optional SSH server host private keys. Provide one complete Base64-encoded private key per line; multiple keys are supported. When unset or empty, an Ed25519 host key is generated and its Base64 value is printed in the container logs. |
| `BACKUP_USERNAME` | `backupuser` | SSH login username. The account is created at startup. |
| `PUB_KEY` | Required | Authorized client OpenSSH public keys, one per line, without `authorized_keys` options. |
| `NO_OVERWRITE` | `false` | When `true`, skips files that already exist at the destination. |
| `NO_DEL` | `false` | When `true`, rejects client `--delete*` and `--remove*` options. |

Both flags accept only lowercase `true` or `false`; other values cause startup to fail. The flags operate independently. By default, clients can update existing files and request deletions; the server does not perform cleanup on its own.

Usernames must be at most 32 characters long and contain only lowercase letters, digits, underscores, or hyphens. The first character must be a lowercase letter or underscore. Existing system accounts in the image cannot be reused.

## Run

Set `PUB_KEY` to the uploading client's OpenSSH public key. If the Docker host does not have the client's public key at the path below, copy it there or use the correct path.

```sh
PUB_KEY="$(cat "$HOME/.ssh/id_ed25519.pub")"
export PUB_KEY

docker run -d --name rsync-receiver \
  -p 2222:22 \
  -v backup-data:/data \
  -e PUB_KEY \
  -e BACKUP_USERNAME=archive \
  -e NO_OVERWRITE=false \
  -e NO_DEL=false \
  henry42/rsync-receiver:latest

unset PUB_KEY
```

## Upload files

Run this command on the client, replacing `server` with the Docker host's address. The destination maps to `/data` inside the container:

```sh
rsync -av -e 'ssh -p 2222' ./source/ archive@server:.
```

The client must use the private key corresponding to a public key in `PUB_KEY`.

## SSH keys

Host private keys identify the server, while `PUB_KEY` contains the client public keys allowed to log in. Keep the same host keys for the lifetime of a service. Multiple host keys can provide different algorithms; SSH negotiates which one to use.

When `SSH_HOST_KEYS_B64` is unset or empty, the container generates an Ed25519 server host key on its first startup and reuses it on subsequent restarts of the same container. After startup validation succeeds, it prints a warning and a reusable value in this format:

```text
SSH_HOST_KEYS_B64=<base64-encoded-private-host-key>
```

View it with:

```sh
docker logs rsync-receiver
```

This value is a **private server host key**, so keep the logs private and save the value securely. When creating a replacement container, export `SSH_HOST_KEYS_B64` with the saved value (the text after `=`) and add `-e SSH_HOST_KEYS_B64` to the run command above. Reusing it keeps the same SSH host fingerprint; recreating the container without it generates a new identity. The backup volume does not store this key.

You may also supply your own host private keys, without passphrases, using `SSH_HOST_KEYS_B64`. Each line must contain the complete, unwrapped Base64 encoding of one private key. Supplied keys are validated and are not printed in the logs. Invalid supplied keys cause startup to fail instead of generating a replacement.

Invalid keys or configuration cause the container to stop during startup. Base64 is only an encoding; anyone with Docker management access can still inspect the environment variables.

## Storage

The example stores backups in the Docker volume `backup-data`, mounted at `/data`. Reuse this volume when recreating the container to retain your backups.

At startup, the top-level `/data` directory is assigned to the login account and given permissions of `700`. Existing files are not modified recursively. When bind-mounting a host directory, use a dedicated directory and ensure its existing contents are accessible to the account's UID/GID.

`NO_OVERWRITE=true` works well when each upload uses a separate dated directory: files already present at the same path are skipped. `NO_DEL=true` restricts rrsync options; it does not provide immutable storage. Use snapshots or other storage policies when historical versions need protection.

References: [OpenSSH host private keys](https://man.openbsd.org/sshd#h), [rrsync options](https://download.samba.org/pub/rsync/rrsync.1.html).
