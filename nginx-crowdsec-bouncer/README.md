# Nginx CrowdSec Bouncer

The official Nginx Alpine image with matching Lua/NDK dynamic modules and the
[CrowdSec Nginx bouncer](https://github.com/crowdsecurity/cs-nginx-bouncer).
CrowdSec Security Engine, LAPI and AppSec run separately on your host. This image
contains only the Nginx client; it includes no CrowdSec daemon, Hub or WAF rules.

## Quick start

Use a tag that identifies all three component versions:

```sh
docker pull henry42/nginx-crowdsec-bouncer:nginx1.31.8-alpine3.24-bouncer1.2.3
```

On the CrowdSec host, register a bouncer:

```sh
sudo cscli bouncers add nginx-docker
```

Provide the returned key at runtime. For example, export `API_KEY` in your shell
and start Nginx with a reachable LAPI address:

```sh
docker run -d --name nginx-crowdsec-bouncer \
  -p 80:80 \
  --add-host host.docker.internal:host-gateway \
  -e API_KEY \
  -e API_URL=http://host.docker.internal:8080 \
  henry42/nginx-crowdsec-bouncer:nginx1.31.8-alpine3.24-bouncer1.2.3
```

AppSec is optional: `API_URL` and `API_KEY` are sufficient for IP decisions.
The existing `CROWDSEC_LAPI_URL` environment variable remains an alias for
`API_URL`. If you provide both names, their values must agree.

The host LAPI must listen on a Docker-accessible host address. Container-local
`127.0.0.1` does not refer to your host. Keep LAPI/AppSec ports private; do not
publish host ports 8080 or 7422 to the Internet.

## Runtime configuration

| Variable | Meaning / default |
| --- | --- |
| `API_URL` | Reachable CrowdSec LAPI URL; no image default. |
| `CROWDSEC_LAPI_URL` | Backward-compatible alias for `API_URL`. |
| `API_KEY` | Registered bouncer API key. |
| `API_KEY_FILE` | Image-specific alternative: read the key from a mounted secret file. |
| `APPSEC_URL` | AppSec endpoint; empty by default, so AppSec is disabled. |
| `APPSEC_FAILURE_ACTION` | `passthrough` (fail-open), or `deny`. |
| `APPSEC_CONNECT_TIMEOUT` | Connection timeout in milliseconds; upstream default `100`. |
| `APPSEC_SEND_TIMEOUT` | Send timeout in milliseconds; upstream default `100`. |
| `APPSEC_PROCESS_TIMEOUT` | Processing/read timeout in milliseconds; bundled Lua library default `500`. |
| `ALWAYS_SEND_TO_APPSEC` | `false`; set `true` to inspect requests even when LAPI has already denied the IP. |
| `APPSEC_DROP_UNREADABLE_BODY` | `false`; set `true` to reject requests whose body cannot be read. |
| `MODE` | `live` (existing image default), or `stream`. |
| `BOUNCING_ON_TYPE` | `all`, `ban`, or `captcha`; default `all`. |
| `FALLBACK_REMEDIATION` | Default `ban`. |
| `REQUEST_TIMEOUT` | LAPI timeout in milliseconds; default `3000`. |
| `UPDATE_FREQUENCY` | Stream polling interval in seconds; default `10`. |
| `SSL_VERIFY` | `true`; certificate verification for HTTPS endpoints. |

All bouncer/AppSec names above except `API_KEY_FILE` and the legacy alias are
upstream configuration names exposed as environment overrides by this image.
Use positive integers for timeout/interval overrides and `true`/`false` for booleans.
The processing timeout follows the pinned Lua code; some upstream documentation
examples use `1000`, which you can set explicitly.

When using environment configuration, supply a key and at least one of `API_URL`
or `APPSEC_URL`. Each startup, including restart, regenerates the main configuration
from a clean template. The official `/docker-entrypoint.sh` remains in charge;
`/docker-entrypoint.d/40-crowdsec-config.sh` renders the bouncer configuration.

Use either `API_KEY` or `API_KEY_FILE`. A secret file is read again on restart,
and the generated configuration is restricted to root. Keys are never build arguments,
image environment defaults or image labels. Keep secret files outside Git.
`API_KEY_FILE` also avoids putting the key in the container environment.

For HTTP URLs supplied through the environment, host aliases found in `/etc/hosts`
are resolved at startup. This makes Compose `extra_hosts` / `host-gateway` work
with Lua cosockets. Nothing in the image hardcodes a host alias or endpoint.
For other DNS names, configure an Nginx `resolver` appropriate for your network.
HTTPS names are retained for certificate/SNI validation and must resolve through
that resolver; `/etc/hosts` alone is insufficient for Lua HTTPS requests.

## Using CrowdSec AppSec

This image does **not** run the AppSec engine. The architecture is:

```text
Internet
   |
Nginx container
   |
CrowdSec Nginx Lua bouncer
   +-- LAPI   --> Host CrowdSec :8080
   +-- AppSec --> Host CrowdSec :7422
   |
upstream application
```

On the CrowdSec host, install the rule collections:

```sh
sudo cscli collections install \
  crowdsecurity/appsec-virtual-patching \
  crowdsecurity/appsec-generic-rules
```

Enable an AppSec acquisition on the host. For example, in
`/etc/crowdsec/acquis.d/appsec.yaml`:

```yaml
source: appsec
listen_addr: 172.17.0.1:7422
appsec_configs:
  - crowdsecurity/appsec-default
labels:
  type: appsec
```

Replace `172.17.0.1` with your actual host Docker bridge/private address. Configure
the existing host LAPI listener on a similarly reachable private address, and restart
CrowdSec after changing its host configuration. Limit both listeners with host
firewall rules to the intended Docker subnet. Do not expose them to the Internet.
The upstream single-host examples use loopback, which bridge-mode containers
cannot reach as the host.

### Minimal Docker Compose example

Save the registered bouncer key in `/etc/nginx-crowdsec/api-key` on the host, outside
your repository. Restrict its host permissions to the administrator/Docker daemon.

```yaml
services:
  nginx:
    image: henry42/nginx-crowdsec-bouncer:nginx1.31.8-alpine3.24-bouncer1.2.3
    ports:
      - "80:80"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      API_URL: http://host.docker.internal:8080
      API_KEY_FILE: /run/secrets/crowdsec_api_key
      APPSEC_URL: http://host.docker.internal:7422
      APPSEC_FAILURE_ACTION: passthrough
      APPSEC_CONNECT_TIMEOUT: "100"
      APPSEC_SEND_TIMEOUT: "100"
      APPSEC_PROCESS_TIMEOUT: "1000"
      ALWAYS_SEND_TO_APPSEC: "false"
      APPSEC_DROP_UNREADABLE_BODY: "false"
    secrets:
      - crowdsec_api_key
    restart: unless-stopped

secrets:
  crowdsec_api_key:
    file: /etc/nginx-crowdsec/api-key
```

The host-gateway feature requires Docker Engine 20.10 or newer. Remove `APPSEC_URL`
to use only LAPI/IP decisions. The example serves the default Nginx page; mount
your application/reverse-proxy configuration as described below.

`passthrough` keeps requests flowing when AppSec is unreachable. It does not
bypass a valid LAPI ban or a successful AppSec block response. Setting
`APPSEC_DROP_UNREADABLE_BODY=true` deliberately rejects unreadable bodies even
with fail-open enabled. In particular, upstream documents limits when inspecting
HTTP/2 or HTTP/3 request bodies without Content-Length; choose this setting for
your application's availability and inspection requirements.

See the [upstream AppSec guide](https://docs.crowdsec.net/docs/next/appsec/quickstart/nginxopenresty/)
and [Nginx bouncer configuration](https://docs.crowdsec.net/u/bouncers/nginx/).

## Mounted configuration and Nginx configuration

To manage the complete bouncer configuration yourself, copy the blank template:

```sh
docker run --rm --entrypoint cat \
  henry42/nginx-crowdsec-bouncer:nginx1.31.8-alpine3.24-bouncer1.2.3 \
  /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.example \
  > crowdsec-nginx-bouncer.conf
```

Edit the file locally and mount it read-only at
`/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf`. Leave all bouncer environment
overrides, including `API_KEY_FILE`, unset in this mode. The main file is not
rewritten. This mode also supports upstream mTLS settings. For endpoints in mounted
files, use reachable IP addresses or configure working DNS and an Nginx resolver.

The optional `/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.local` file overrides
individual values after the main file is loaded. It is not included in the image
or generated at startup: create and mount it yourself. It takes precedence even
over values rendered from the environment. Do not keep an API key in Git.

Mount Nginx server/reverse-proxy configuration under `/etc/nginx/conf.d/`.
Existing `/etc/nginx/http.d/` mounts remain supported through an HTTP-context
include in the bouncer configuration. If replacing `/etc/nginx/nginx.conf`, preserve
the two Lua/NDK `load_module` lines and the bouncer HTTP configuration include.
Mounting over all of `/etc/nginx/conf.d/` must also retain `00-crowdsec.conf`;
otherwise the bouncer hooks will not execute. Prefer mounting individual files.

## CAPTCHA (optional)

When no CAPTCHA keys are configured, upstream logs:

```text
error loading captcha plugin: no recaptcha site key provided, can't use recaptcha
```

That message alone does not stop Nginx or disable normal IP bans. With the default
`FALLBACK_REMEDIATION=ban`, CAPTCHA decisions fall back to blocking the request.
Upstream Lua behavior is preserved.

To enable CAPTCHA, obtain matching keys from `recaptcha`, `hcaptcha` or `turnstile`.
Create a local override file (these keys are separate from the CrowdSec API key):

```sh
cat > crowdsec-nginx-bouncer.conf.local <<'EOF'
CAPTCHA_PROVIDER=recaptcha
SITE_KEY=your-captcha-site-key
SECRET_KEY=your-captcha-secret-key
EOF
```

Mount it at `/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.local:ro` and recreate
the container. CAPTCHA settings are configured through the file, not environment
variables. Configure a working Nginx resolver for the provider's HTTPS endpoint.

## Verify and troubleshoot

```sh
docker exec nginx-crowdsec-bouncer nginx -t
docker exec nginx-crowdsec-bouncer nginx -V
docker logs -f nginx-crowdsec-bouncer
```

`nginx -V` describes the unchanged official binary; dynamically loaded modules do
not appear as compile-time additions to that binary. `nginx -t` must load them
successfully, without binary compatibility, unknown directive, missing library or
Lua module errors. The optional CAPTCHA message above is separate from these failures.

For the Compose deployment, test host connectivity from the container:

```sh
docker compose exec nginx wget -S -O /dev/null http://host.docker.internal:8080/
docker compose exec nginx wget -S -O /dev/null http://host.docker.internal:7422/
```

An HTTP 401/404 response can prove network reachability, but does not prove
authentication or successful WAF inspection. Check the URL, host listener address
and firewall if the connection is refused or times out.

Send a request to a route covered by your AppSec rules, then check the **CrowdSec
host**:

```sh
curl -i http://localhost/.env
sudo cscli metrics show appsec
```

Confirm that AppSec processed the request and, when applicable, recorded the block.
A 403 alone is insufficient: your own Nginx/application configuration could return it.
For a fail-open check on a disposable deployment, temporarily point `APPSEC_URL`
to an unreachable endpoint and request a known healthy application page. It should
still work with `APPSEC_FAILURE_ACTION=passthrough`; restore the real endpoint afterward.

Access and error logs use standard output/error. The image's build and CI checks,
version policy and source locks are documented in [BUILDING.md](BUILDING.md).
