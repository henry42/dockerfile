#!/bin/sh
# Executed by the official Nginx /docker-entrypoint.d/ mechanism.
set -eu

CONFIG_PATH=/etc/crowdsec/bouncers
settings='API_URL API_KEY APPSEC_URL APPSEC_FAILURE_ACTION APPSEC_CONNECT_TIMEOUT APPSEC_SEND_TIMEOUT APPSEC_PROCESS_TIMEOUT ALWAYS_SEND_TO_APPSEC APPSEC_DROP_UNREADABLE_BODY MODE BOUNCING_ON_TYPE FALLBACK_REMEDIATION REQUEST_TIMEOUT UPDATE_FREQUENCY SSL_VERIFY'
configured=false
for setting in $settings CROWDSEC_LAPI_URL API_KEY_FILE; do
    if printenv "$setting" >/dev/null 2>&1; then
        configured=true
        break
    fi
done

# Mounted main/.local configurations remain under the user's control.
if [ "$configured" = false ]; then
    exit 0
fi

if [ -n "${API_URL:-}" ] && [ -n "${CROWDSEC_LAPI_URL:-}" ] && \
    [ "$API_URL" != "$CROWDSEC_LAPI_URL" ]; then
    printf '%s\n' 'API_URL and CROWDSEC_LAPI_URL must agree when both are set.' >&2
    exit 1
fi
API_URL=${API_URL:-${CROWDSEC_LAPI_URL:-}}
API_KEY=${API_KEY:-}
if [ -n "${API_KEY_FILE:-}" ]; then
    [ -z "$API_KEY" ] || { printf '%s\n' 'Set either API_KEY or API_KEY_FILE, not both.' >&2; exit 1; }
    [ -f "$API_KEY_FILE" ] && [ -r "$API_KEY_FILE" ] || {
        printf '%s\n' 'API_KEY_FILE must be a readable secret file.' >&2
        exit 1
    }
    API_KEY=$(cat "$API_KEY_FILE")
fi
[ -n "$API_URL" ] || [ -n "${APPSEC_URL:-}" ] || {
    printf '%s\n' 'Set API_URL (or CROWDSEC_LAPI_URL), APPSEC_URL, or use mounted configuration without environment overrides.' >&2
    exit 1
}
: "${API_KEY:?Provide API_KEY or API_KEY_FILE when using environment configuration.}"
export API_URL API_KEY

umask 077
config_tmp=$(mktemp "$CONFIG_PATH/.crowdsec-nginx-bouncer.conf.XXXXXX")
trap 'rm -f "$config_tmp"' 0
# ENVIRON avoids passing the API key on the awk command line. Only supported
# settings are substituted; each restart starts from the clean upstream template.
awk -v settings="$settings" '
    function fail(key) {
        print "Invalid runtime setting: " key > "/dev/stderr"
        exit 1
    }
    function endpoint(value, rest, authority, host, suffix, address) {
        # Lua cosockets do not consult /etc/hosts. Resolve HTTP host aliases,
        # including deployment-provided host-gateway entries, at startup.
        # Keep HTTPS names unchanged for certificate/SNI validation.
        if (value !~ /^http:\/\//) return value
        rest = substr(value, 8)
        authority = rest
        sub(/\/.*/, "", authority)
        if (authority ~ /^\[/ || authority ~ /@/) return value
        host = authority
        sub(/:.*/, "", host)
        address = hosts[tolower(host)]
        if (address == "") return value
        if (address ~ /:/) address = "[" address "]"
        suffix = substr(rest, length(authority) + 1)
        return "http://" address substr(authority, length(host) + 1) suffix
    }
    BEGIN {
        while ((getline line < "/etc/hosts") > 0) {
            sub(/#.*/, "", line)
            sub(/^[ \t]+/, "", line)
            count = split(line, fields, /[ \t]+/)
            for (i = 2; i <= count; i++) {
                name = tolower(fields[i])
                if (!(name in hosts) || fields[1] !~ /:/) hosts[name] = fields[1]
            }
        }
        close("/etc/hosts")
        count = split(settings, names, " ")
        for (i = 1; i <= count; i++) {
            key = names[i]
            if (key in ENVIRON) {
                value = ENVIRON[key]
                if (value ~ /[\r\n]/) fail(key)
                if (key ~ /^(API_URL|APPSEC_URL)$/ && value != "" && value !~ /^https?:\/\//) fail(key)
                if (key ~ /^(ALWAYS_SEND_TO_APPSEC|APPSEC_DROP_UNREADABLE_BODY|SSL_VERIFY)$/ && value !~ /^(true|false)$/) fail(key)
                if (key == "APPSEC_FAILURE_ACTION" && value !~ /^(passthrough|deny)$/) fail(key)
                if (key ~ /^(APPSEC_CONNECT_TIMEOUT|APPSEC_SEND_TIMEOUT|APPSEC_PROCESS_TIMEOUT|REQUEST_TIMEOUT|UPDATE_FREQUENCY)$/ && value !~ /^[1-9][0-9]*$/) fail(key)
                if (key == "API_URL" || key == "APPSEC_URL") value = endpoint(value)
                overrides[key] = value
            }
        }
    }
    /^[A-Z_]+=/ {
        key = substr($0, 1, index($0, "=") - 1)
        if (key in overrides) $0 = key "=" overrides[key]
    }
    { print }
' "$CONFIG_PATH/crowdsec-nginx-bouncer.conf.example" > "$config_tmp"
mv -f "$config_tmp" "$CONFIG_PATH/crowdsec-nginx-bouncer.conf"
trap - 0

if [ -z "${NGINX_ENTRYPOINT_QUIET_LOGS:-}" ]; then
    printf '%s\n' 'CrowdSec runtime configuration generated.'
fi
