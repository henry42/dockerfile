#!/bin/sh

set -eu

LUA_MOD_DIR="./lua-mod"
NGINX_CONF="crowdsec_nginx.conf"
NGINX_CONF_DIR="/etc/nginx/http.d"
LIB_PATH="/usr/local/lua/crowdsec"
CONFIG_PATH="/etc/crowdsec/bouncers"
DATA_PATH="/var/lib/crowdsec/lua"
SILENT="false"

usage() {
      echo "Usage:"
      echo "    ./install.sh -h                 Display this help message."
      echo "    ./install.sh                    Install the bouncer in interactive mode"
      echo "    ./install.sh -y                 Install the bouncer and accept everything"
      exit 0
}


# Accept command-line arguments using POSIX sh syntax.
while [ "$#" -gt 0 ]; do
    case "$1" in
        -y|--yes)
            SILENT="true"
        ;;
        -h|--help)
            usage
        ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 1
        ;;
    esac
    shift
done

install_dependencies() {
    if [ "$SILENT" != "true" ]; then
        printf 'Install Nginx, Lua and temporary build dependencies? (Y/n) '
        IFS= read -r answer
        case "$answer" in
            ''|[Yy]|[Yy][Ee][Ss]) ;;
            *) printf '%s\n' 'Installation cancelled.' >&2; exit 1 ;;
        esac
    fi

    # apk resolves exact package names and keeps runtime packages after cleanup.
    apk add --no-cache nginx nginx-mod-http-lua lua5.1 gettext-envsubst ca-certificates
    apk add --no-cache --virtual .crowdsec-build-deps gcc musl-dev lua5.1-dev luarocks5.1
}

install_bouncer() {
    mkdir -p "$LIB_PATH/plugins/crowdsec" "$DATA_PATH/templates" "$NGINX_CONF_DIR"
    cp "nginx/$NGINX_CONF" "$NGINX_CONF_DIR/$NGINX_CONF"
    cp -R "$LUA_MOD_DIR/lib/." "$LIB_PATH/"
    cp -R "$LUA_MOD_DIR/templates/." "$DATA_PATH/templates/"

    # Alpine's nginx.conf already loads dynamic modules. http.d is inside http {}.
    luarocks-5.1 --tree=/usr/local install lua-resty-http 0.17.1-0
    luarocks-5.1 --tree=/usr/local install lua-cjson 2.1.0.10-1
}

configure_bouncer() {
    mkdir -p "$CONFIG_PATH"
    cp "$LUA_MOD_DIR/config_example.conf" "$CONFIG_PATH/crowdsec-nginx-bouncer.conf.example"

    # Preserve an existing configuration when reinstalling.
    if [ -f "$CONFIG_PATH/crowdsec-nginx-bouncer.conf" ]; then
        return
    fi

    lapi_port="8080"
    if [ -z "${API_KEY:-}" ] && command -v cscli >/dev/null 2>&1; then
        suffix=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
        API_KEY=$(cscli bouncers add "crowdsec-nginx-bouncer-$suffix" -o raw)
        listen_uri=$(cscli config show --key Config.API.Server.ListenURI)
        if [ -n "$listen_uri" ]; then
            lapi_port=${listen_uri##*:}
        fi
        printf '%s\n' 'Bouncer registered to the CrowdSec Local API.'
    fi

    API_KEY="${API_KEY:-}" \
        CROWDSEC_LAPI_URL="${CROWDSEC_LAPI_URL:-http://127.0.0.1:$lapi_port}" \
        envsubst '$API_KEY $CROWDSEC_LAPI_URL' \
        < "$LUA_MOD_DIR/config_example.conf" \
        > "$CONFIG_PATH/crowdsec-nginx-bouncer.conf"
}

install_dependencies
install_bouncer
configure_bouncer
apk del --no-cache .crowdsec-build-deps

printf '%s\n' 'crowdsec-nginx-bouncer installed successfully'
