#!/bin/sh
# Build-stage installer. Never registers a bouncer or configures a CrowdSec host.
set -eu

case "${1:-}" in
    ''|-y|--yes) ;;
    -h|--help) printf '%s\n' 'Build-stage installer; versions are supplied by Dockerfile ARGs.'; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
esac

: "${EXPECTED_NGINX_VERSION:?}" "${ALPINE_VERSION:?}" "${BOUNCER_VERSION:?}"
actual_version=$(nginx -v 2>&1)
[ "$actual_version" = "nginx version: nginx/$EXPECTED_NGINX_VERSION" ] || {
    printf '%s\n' 'The official image digest does not match NGINX_VERSION.' >&2
    exit 1
}
[ "$(cut -d. -f1,2 /etc/alpine-release)" = "$ALPINE_VERSION" ] || {
    printf '%s\n' 'The official image digest does not match ALPINE_VERSION.' >&2
    exit 1
}
printf 'Nginx=%s Alpine=%s CrowdSec bouncer=%s\n' "$EXPECTED_NGINX_VERSION" "$ALPINE_VERSION" "$BOUNCER_VERSION"

work=/build
out=/out
jobs=$(nproc)
mkdir -p "$work/downloads" "$work/src" "$out/usr/local/lib" \
    "$out/usr/lib/nginx/modules" "$out/usr/local/share/lua/5.1" \
    "$out/etc/nginx/conf.d" "$out/etc/nginx/http.d" \
    "$out/etc/crowdsec/bouncers" "$out/var/lib/crowdsec/lua/templates"

fetch() {
    archive=$1
    url=$2
    checksum=$(awk -v name="$archive" '$2 == name { print $1 }' "$work/source-checksums.sha256")
    [ "${#checksum}" -eq 64 ] || {
        printf 'Missing reviewed SHA256 for %s; update source-checksums.sha256 first.\n' "$archive" >&2
        exit 1
    }
    if [ "$archive" = "crowdsec-nginx-bouncer-$BOUNCER_VERSION.tgz" ] && \
        [ -f "$work/vendor/crowdsec-nginx-bouncer-v$BOUNCER_VERSION.tgz" ]; then
        cp "$work/vendor/crowdsec-nginx-bouncer-v$BOUNCER_VERSION.tgz" "$work/downloads/$archive"
    else
        curl --fail --location --silent --show-error --retry 3 "$url" -o "$work/downloads/$archive"
    fi
    (cd "$work/downloads" && printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c -)
}

unpack() {
    mkdir -p "$work/src/$2"
    tar -xzf "$work/downloads/$1" --strip-components=1 -C "$work/src/$2"
}

fetch "nginx-$EXPECTED_NGINX_VERSION.tar.gz" "https://nginx.org/download/nginx-$EXPECTED_NGINX_VERSION.tar.gz"
fetch "lua-nginx-module-$LUA_NGINX_MODULE_VERSION.tar.gz" "https://codeload.github.com/openresty/lua-nginx-module/tar.gz/refs/tags/v$LUA_NGINX_MODULE_VERSION"
fetch "ngx_devel_kit-$NDK_VERSION.tar.gz" "https://codeload.github.com/vision5/ngx_devel_kit/tar.gz/refs/tags/v$NDK_VERSION"
fetch "luajit2-$LUAJIT_VERSION.tar.gz" "https://codeload.github.com/openresty/luajit2/tar.gz/refs/tags/v$LUAJIT_VERSION"
fetch "lua-resty-core-$RESTY_CORE_REF.tar.gz" "https://codeload.github.com/openresty/lua-resty-core/tar.gz/$RESTY_CORE_REF"
fetch "lua-resty-lrucache-$RESTY_LRUCACHE_VERSION.tar.gz" "https://codeload.github.com/openresty/lua-resty-lrucache/tar.gz/refs/tags/v$RESTY_LRUCACHE_VERSION"
fetch "lua-resty-http-$RESTY_HTTP_VERSION.tar.gz" "https://codeload.github.com/ledgetech/lua-resty-http/tar.gz/refs/tags/v$RESTY_HTTP_VERSION"
fetch "lua-resty-string-$RESTY_STRING_VERSION.tar.gz" "https://codeload.github.com/openresty/lua-resty-string/tar.gz/refs/tags/v$RESTY_STRING_VERSION"
fetch "lua-resty-openssl-$RESTY_OPENSSL_VERSION.tar.gz" "https://codeload.github.com/fffonion/lua-resty-openssl/tar.gz/refs/tags/$RESTY_OPENSSL_VERSION"
fetch "lua-cjson-$CJSON_VERSION.tar.gz" "https://codeload.github.com/openresty/lua-cjson/tar.gz/refs/tags/$CJSON_VERSION"
fetch "crowdsec-nginx-bouncer-$BOUNCER_VERSION.tgz" "https://github.com/crowdsecurity/cs-nginx-bouncer/releases/download/v$BOUNCER_VERSION/crowdsec-nginx-bouncer.tgz"

unpack "nginx-$EXPECTED_NGINX_VERSION.tar.gz" nginx
unpack "lua-nginx-module-$LUA_NGINX_MODULE_VERSION.tar.gz" lua-module
unpack "ngx_devel_kit-$NDK_VERSION.tar.gz" ndk
unpack "luajit2-$LUAJIT_VERSION.tar.gz" luajit
unpack "lua-resty-core-$RESTY_CORE_REF.tar.gz" resty-core
unpack "lua-resty-lrucache-$RESTY_LRUCACHE_VERSION.tar.gz" resty-lrucache
unpack "lua-resty-http-$RESTY_HTTP_VERSION.tar.gz" resty-http
unpack "lua-resty-string-$RESTY_STRING_VERSION.tar.gz" resty-string
unpack "lua-resty-openssl-$RESTY_OPENSSL_VERSION.tar.gz" resty-openssl
unpack "lua-cjson-$CJSON_VERSION.tar.gz" cjson
unpack "crowdsec-nginx-bouncer-$BOUNCER_VERSION.tgz" bouncer

make -C "$work/src/luajit" -j "$jobs" PREFIX=/usr/local
make -C "$work/src/luajit" install PREFIX=/usr/local
cp -a /usr/local/lib/libluajit-5.1.so* "$out/usr/local/lib/"
export LUAJIT_LIB=/usr/local/lib LUAJIT_INC=/usr/local/include/luajit-2.1
export LD_LIBRARY_PATH=/usr/local/lib

# Reuse the installed official binary's configure flags, including hardening.
# eval preserves the quoted --with-cc-opt/--with-ld-opt values from nginx -V.
configure_args=$(nginx -V 2>&1 | sed -n 's/^configure arguments: //p')
[ -n "$configure_args" ] || { printf '%s\n' 'Cannot read official Nginx configure arguments.' >&2; exit 1; }
cd "$work/src/nginx"
eval "set -- $configure_args"
ld_opt=
for option do
    case "$option" in --with-ld-opt=*) ld_opt=${option#--with-ld-opt=} ;; esac
done
./configure "$@" --with-compat \
    "--with-ld-opt=$ld_opt -Wl,-rpath,/usr/local/lib" \
    "--add-dynamic-module=$work/src/ndk" \
    "--add-dynamic-module=$work/src/lua-module"
make -j "$jobs" modules
cp objs/ndk_http_module.so objs/ngx_http_lua_module.so "$out/usr/lib/nginx/modules/"

for library in resty-core resty-lrucache resty-http resty-string resty-openssl; do
    cp -R "$work/src/$library/lib/." "$out/usr/local/share/lua/5.1/"
done
make -C "$work/src/cjson" -j "$jobs" LUA_INCLUDE_DIR="$LUAJIT_INC" CFLAGS='-O2 -fPIC'
make -C "$work/src/cjson" install DESTDIR="$out" LUA_INCLUDE_DIR="$LUAJIT_INC"
LUA_CPATH="$out/usr/local/lib/lua/5.1/?.so;;" /usr/local/bin/luajit -e 'assert(require("cjson").decode("{\"ok\":true}").ok)'

mkdir -p "$out/usr/local/lua/crowdsec"
cp -R "$work/src/bouncer/lua-mod/lib/." "$out/usr/local/lua/crowdsec/"
cp "$work/src/bouncer/lua-mod/LICENSE" "$out/usr/local/lua/crowdsec/LICENSE"
cp -R "$work/src/bouncer/lua-mod/templates/." "$out/var/lib/crowdsec/lua/templates/"
# Keep upstream defaults; never render credentials or endpoints at build time.
sed 's/${CROWDSEC_LAPI_URL}//g; s/${API_KEY}//g' \
    "$work/src/bouncer/lua-mod/config_example.conf" \
    > "$out/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.example"
if grep -Eq '\$\{[A-Z_]+\}' "$out/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.example"; then
    printf '%s\n' 'Unresolved upstream template placeholders; review this bouncer release.' >&2
    exit 1
fi
cp "$out/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.example" \
    "$out/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf"

awk '
    /^lua_package_path / {
        print "lua_package_path '\''/usr/local/lua/crowdsec/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;;'\'';"
        print "lua_package_cpath '\''/usr/local/lib/lua/5.1/?.so;;'\'';"
        next
    }
    { print }
' "$work/src/bouncer/nginx/crowdsec_nginx.conf" > "$out/etc/nginx/conf.d/00-crowdsec.conf"
printf '\n# Compatibility with existing image deployments.\ninclude /etc/nginx/http.d/*.conf;\n' \
    >> "$out/etc/nginx/conf.d/00-crowdsec.conf"
{
    printf '%s\n' 'load_module /usr/lib/nginx/modules/ndk_http_module.so;' \
        'load_module /usr/lib/nginx/modules/ngx_http_lua_module.so;'
    cat /etc/nginx/nginx.conf
} > "$out/etc/nginx/nginx.conf"

find "$out/usr/local/lib" "$out/usr/lib/nginx/modules" -type f -name '*.so*' -exec strip --strip-unneeded '{}' ';'
printf '%s\n' 'Installed CrowdSec client and Lua modules; the official Nginx executable is unchanged.'
