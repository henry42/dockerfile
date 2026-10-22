#!/bin/sh

set -eu

entrypoint_log() {
    if [ -z "${NGINX_ENTRYPOINT_QUIET_LOGS:-}" ]; then
        printf '%s\n' "$*"
    fi
}

if [ "${1:-}" = "nginx" ]; then
    CONFIG_PATH="/etc/crowdsec/bouncers"

    if [ -n "${API_KEY:-}" ] || [ -n "${CROWDSEC_LAPI_URL:-}" ]; then
        : "${API_KEY:?Set both API_KEY and CROWDSEC_LAPI_URL, or leave both unset to use a mounted configuration.}"
        : "${CROWDSEC_LAPI_URL:?Set both API_KEY and CROWDSEC_LAPI_URL, or leave both unset to use a mounted configuration.}"

        # Render successfully before replacing the active configuration.
        config_tmp=$(mktemp "$CONFIG_PATH/.crowdsec-nginx-bouncer.conf.XXXXXX")
        trap 'rm -f "$config_tmp"' 0
        API_KEY="$API_KEY" CROWDSEC_LAPI_URL="$CROWDSEC_LAPI_URL" \
            envsubst '$API_KEY $CROWDSEC_LAPI_URL' \
            < "$CONFIG_PATH/crowdsec-nginx-bouncer.conf.example" > "$config_tmp"
        mv -f "$config_tmp" "$CONFIG_PATH/crowdsec-nginx-bouncer.conf"
        trap - 0

        entrypoint_log "entrypoint.sh: info: Use CROWDSEC_LAPI_URL $CROWDSEC_LAPI_URL"
    fi
fi

exec "$@"
