#!/bin/sh
# vim:sw=4:ts=4:et

set -e

entrypoint_log() {
    if [ -z "${NGINX_ENTRYPOINT_QUIET_LOGS:-}" ]; then
        echo "$@"
    fi
}

ME=$(basename "$0")

CONFIG_PATH="/etc/crowdsec/bouncers/"

if [ -n "$API_KEY" -a -n "$CROWDSEC_LAPI_URL" ];then
    API_KEY=${API_KEY} CROWDSEC_LAPI_URL=${CROWDSEC_LAPI_URL} envsubst '$API_KEY $CROWDSEC_LAPI_URL' < ${CONFIG_PATH}crowdsec-nginx-bouncer.conf.example | tee -a "${CONFIG_PATH}crowdsec-nginx-bouncer.conf" >/dev/null
    entrypoint_log "$ME: info: Use CROWDSEC_LAPI_URL $CROWDSEC_LAPI_URL"
fi


exit 0