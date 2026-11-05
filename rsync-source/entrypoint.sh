#!/bin/sh
set -eu
umask 077

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

BACKUP_USERNAME=${BACKUP_USERNAME-backupuser}
PUID=${PUID-1000}
PGID=${PGID-1000}
ALLOW_SOURCE_DELETE=${ALLOW_SOURCE_DELETE-false}

allowed_ips=$(python3 - <<'PY'
import ipaddress
import os
import re
import sys

value = os.environ.get("ALLOWED_IPS", "")
if not value:
    sys.exit(0)

try:
    entries = re.split(r"[\s,]+", value.strip(" \t\r\n,"))
    addresses = []
    for entry in entries:
        if not re.fullmatch(r"[0-9a-fA-F:./]+", entry):
            raise ValueError()
        address = ipaddress.ip_network(entry, strict=False) if "/" in entry else ipaddress.ip_address(entry)
        addresses.append(str(address))
except ValueError:
    sys.exit("ALLOWED_IPS must contain IPv4/IPv6 addresses or CIDR networks separated by commas or whitespace.")

print(",".join(dict.fromkeys(addresses)))
PY
) || fail 'Invalid ALLOWED_IPS.'

key_options=restrict
if [ -n "$allowed_ips" ]; then
    key_options="$key_options,from=\"$allowed_ips\""
fi

case "$BACKUP_USERNAME" in
    ''|[!a-z_]*|*[!a-z0-9_-]*)
        fail 'BACKUP_USERNAME must start with a lowercase letter or underscore and contain only lowercase letters, digits, underscores or hyphens.'
        ;;
esac
[ "${#BACKUP_USERNAME}" -le 32 ] || fail 'BACKUP_USERNAME must be at most 32 characters.'

case "$ALLOW_SOURCE_DELETE" in
    true|false) ;;
    *) fail 'ALLOW_SOURCE_DELETE must be true or false.' ;;
esac

for setting in "$PUID" "$PGID"; do
    case "$setting" in
        ''|0*|*[!0-9]*) fail 'PUID and PGID must be positive decimal integers without leading zeros.' ;;
    esac
    [ "${#setting}" -le 10 ] && [ "$setting" -le 2147483647 ] || fail 'PUID and PGID must be at most 2147483647.'
done
[ "$PUID" -ge 1000 ] || fail 'PUID must be at least 1000.'

[ -n "${PUB_KEY:-}" ] || fail 'PUB_KEY is required.'
[ "$(id -u)" -eq 0 ] || fail 'The entrypoint must run as root to configure sshd and the backup user.'

runtime_dir=/run/rsync-source
config_file=$runtime_dir/sshd_config
authorized_keys=/etc/ssh/source_authorized_keys
home_dir=/home/$BACKUP_USERNAME

mkdir -p "$runtime_dir" /run/sshd
chmod 700 "$runtime_dir"
rm -f "$runtime_dir"/host_key_[0-9]*

cat > "$config_file" <<EOF
Port 22
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin no
AllowUsers $BACKUP_USERNAME
AuthorizedKeysFile $authorized_keys
DisableForwarding yes
PermitTTY no
PermitUserRC no
PrintMotd no
LogLevel VERBOSE
EOF

generated_key_file=''
if [ -n "${SSH_HOST_KEYS_B64:-}" ]; then
    # Each line contains one complete, unwrapped base64-encoded private key.
    printf '%s\n' "$SSH_HOST_KEYS_B64" | tr -d '\r' > "$runtime_dir/encoded_host_keys"
    key_count=0
    while IFS= read -r encoded_key || [ -n "$encoded_key" ]; do
        [ -n "$encoded_key" ] || continue
        key_count=$((key_count + 1))
        key_file=$runtime_dir/host_key_$key_count
        if ! printf '%s' "$encoded_key" | base64 -d > "$key_file" 2>/dev/null; then
            fail "Host key $key_count is not valid base64."
        fi
        chmod 600 "$key_file"
        if ! ssh-keygen -y -P '' -f "$key_file" > /dev/null 2>&1; then
            fail "Host key $key_count must be a valid private key without a passphrase."
        fi
        printf 'HostKey %s\n' "$key_file" >> "$config_file"
    done < "$runtime_dir/encoded_host_keys"
    rm -f "$runtime_dir/encoded_host_keys"
    [ "$key_count" -gt 0 ] || fail 'SSH_HOST_KEYS_B64 must contain at least one key.'
else
    generated_key_file=$runtime_dir/host_key_generated
    # Preserve this container's automatically generated identity across restarts.
    if [ ! -f "$generated_key_file" ]; then
        ssh-keygen -q -t ed25519 -N '' -f "$generated_key_file"
    fi
    chmod 600 "$generated_key_file"
    ssh-keygen -y -P '' -f "$generated_key_file" > /dev/null 2>&1 || fail 'The automatically generated host key is invalid.'
    printf 'HostKey %s\n' "$generated_key_file" >> "$config_file"
    key_count=1
fi
unset SSH_HOST_KEYS_B64

printf '%s\n' "$PUB_KEY" | tr -d '\r' > "$runtime_dir/public_keys"
unset PUB_KEY
: > "$runtime_dir/authorized_keys"
public_key_count=0
while IFS= read -r public_key || [ -n "$public_key" ]; do
    case "$public_key" in
        ''|\#*) continue ;;
        ssh-*|ecdsa-sha2-*|sk-*) ;;
        *) fail 'PUB_KEY must contain plain OpenSSH public keys, one per line, without authorized_keys options.' ;;
    esac
    printf '%s\n' "$public_key" > "$runtime_dir/public_key"
    ssh-keygen -l -f "$runtime_dir/public_key" > /dev/null 2>&1 || fail 'PUB_KEY contains an invalid public key.'
    printf '%s %s\n' "$key_options" "$public_key" >> "$runtime_dir/authorized_keys"
    public_key_count=$((public_key_count + 1))
done < "$runtime_dir/public_keys"
rm -f "$runtime_dir/public_key" "$runtime_dir/public_keys"
[ "$public_key_count" -gt 0 ] || fail 'PUB_KEY must contain at least one public key.'

if id -u "$BACKUP_USERNAME" > /dev/null 2>&1; then
    # Reuse an account on container restart, but never adopt a system account.
    awk -F: -v user="$BACKUP_USERNAME" -v uid="$PUID" -v gid="$PGID" -v home="$home_dir" '
        $1 == user && $3 == uid && $4 == gid && $6 == home && $7 == "/bin/sh" { found = 1 }
        END { exit !found }
    ' /etc/passwd || fail 'BACKUP_USERNAME conflicts with an existing account or its UID/GID changed. Recreate the container to change PUID or PGID.'
else
    if awk -F: -v uid="$PUID" '$3 == uid { found = 1 } END { exit !found }' /etc/passwd; then
        fail 'PUID is already assigned to another account.'
    fi
    group_name=$(awk -F: -v gid="$PGID" '$3 == gid { print $1; exit }' /etc/group)
    if [ -z "$group_name" ]; then
        group_name=rsync-source
        groupadd -g "$PGID" "$group_name"
    fi
    adduser -D -u "$PUID" -G "$group_name" -h "$home_dir" -s /bin/sh "$BACKUP_USERNAME"
fi
usermod -p '*' "$BACKUP_USERNAME"

cp "$runtime_dir/authorized_keys" "$authorized_keys"
chown root:root "$authorized_keys"
chmod 644 "$authorized_keys"

printf 'ForceCommand /usr/local/bin/rsync-source-command %s\n' "$ALLOW_SOURCE_DELETE" >> "$config_file"

# Source data belongs to the host. Never change its ownership or permissions.
[ -d /data ] || fail '/data must be a directory.'

/usr/sbin/sshd -t -f "$config_file"
if [ -n "$generated_key_file" ]; then
    printf '%s\n' \
        'WARNING: SSH_HOST_KEYS_B64 was not provided. Using an automatically generated Ed25519 server host key.' \
        'WARNING: The following Base64 value contains a PRIVATE SERVER HOST KEY. Keep these logs private and save the value securely.'
    printf 'SSH_HOST_KEYS_B64='
    base64 < "$generated_key_file" | tr -d '\n'
    printf '\n'
    printf '%s\n' 'WARNING: Set SSH_HOST_KEYS_B64 to the value above when recreating this container to keep the same SSH host fingerprint.'
fi
printf 'Service started. Ready for rsync pulls as %s (UID %s, GID %s) with %s host key(s). ALLOW_SOURCE_DELETE=%s\n' "$BACKUP_USERNAME" "$PUID" "$PGID" "$key_count" "$ALLOW_SOURCE_DELETE"
exec /usr/sbin/sshd -D -e -f "$config_file"
