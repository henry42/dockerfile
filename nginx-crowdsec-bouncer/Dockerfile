# Version defaults are the source of truth for local builds and GitHub Actions.
ARG NGINX_VERSION=1.31.8
ARG ALPINE_VERSION=3.24
ARG BOUNCER_VERSION=1.2.3
ARG NGINX_IMAGE_DIGEST=sha256:1ef7ca94d7879df82421428ce13bd1eaa412404953859cf7a5b6512c25e67a60
# Avoid the NGINX_VERSION environment variable inherited from the official image.
ARG EXPECTED_NGINX_VERSION=${NGINX_VERSION}

FROM nginx:${NGINX_VERSION}-alpine${ALPINE_VERSION}@${NGINX_IMAGE_DIGEST} AS nginx-base

FROM nginx-base AS builder
ARG EXPECTED_NGINX_VERSION
ARG ALPINE_VERSION
ARG BOUNCER_VERSION
ARG LUA_NGINX_MODULE_VERSION=0.10.31
ARG NDK_VERSION=0.3.4
ARG LUAJIT_VERSION=2.1-20261023
# This reviewed upstream commit requires ngx_http_lua_module 0.10.31.
# The latest stable resty-core tag (0.1.32) requires 0.10.29 instead.
ARG RESTY_CORE_REF=6fec23e2149c88b33b39fec8a5ebdd67a3e0dd88
ARG RESTY_LRUCACHE_VERSION=0.15
ARG RESTY_HTTP_VERSION=0.18.0
ARG RESTY_STRING_VERSION=0.19
ARG RESTY_OPENSSL_VERSION=1.9.0
ARG CJSON_VERSION=2.1.0.20

RUN apk add --no-cache build-base curl linux-headers openssl-dev pcre2-dev zlib-dev
WORKDIR /build
COPY install.sh source-checksums.sha256 /build/
COPY crowdsec-nginx-bouncer-v*.tgz /build/vendor/
RUN chmod 0755 /build/install.sh && /build/install.sh -y

FROM nginx-base AS runtime
ARG EXPECTED_NGINX_VERSION
ARG ALPINE_VERSION
ARG BOUNCER_VERSION
ARG NGINX_IMAGE_DIGEST
LABEL org.opencontainers.image.title="Nginx CrowdSec Bouncer" \
      org.opencontainers.image.source="https://github.com/henry42/dockerfile" \
      org.opencontainers.image.base.name="nginx:${EXPECTED_NGINX_VERSION}-alpine${ALPINE_VERSION}" \
      org.opencontainers.image.base.digest="${NGINX_IMAGE_DIGEST}" \
      io.henry42.nginx.version="${EXPECTED_NGINX_VERSION}" \
      io.henry42.alpine.version="${ALPINE_VERSION}" \
      io.henry42.bouncer.version="${BOUNCER_VERSION}"

RUN apk add --no-cache libgcc
COPY --from=builder /out/ /
COPY entrypoint.sh /docker-entrypoint.d/40-crowdsec-config.sh
RUN set -eu; \
    chmod 0755 /docker-entrypoint.d/40-crowdsec-config.sh; \
    nginx -t; \
    nginx -V

# Keep the official /docker-entrypoint.sh, CMD, logs and stop signal.
