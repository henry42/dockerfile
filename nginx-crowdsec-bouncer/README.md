# Nginx CrowdSec Bouncer

An Alpine-based Nginx image with the CrowdSec Nginx bouncer, connected to an external
CrowdSec Local API.

Based on [crowdsecurity/cs-nginx-bouncer](https://github.com/crowdsecurity/cs-nginx-bouncer).
Modified for use with Alpine Linux and Docker.

## Quick start

```sh
docker pull henry42/nginx-crowdsec-bouncer
```

You need a running CrowdSec Local API (LAPI) and a bouncer API key registered with it.
Replace the API key and LAPI address below with your own values:

```sh
docker run -d \
  --name nginx-crowdsec-bouncer \
  -p 8080:80 \
  -e API_KEY='your-bouncer-api-key' \
  -e CROWDSEC_LAPI_URL='http://YOUR_CROWDSEC_HOST:8080' \
  henry42/nginx-crowdsec-bouncer
```

## Environment variables

| Variable | Description |
| --- | --- |
| `API_KEY` | Bouncer API key registered with your CrowdSec instance. |
| `CROWDSEC_LAPI_URL` | URL of the CrowdSec Local API, reachable from inside the container. |

Provide both variables together. The bouncer configuration is regenerated on each
startup when they are set. Providing only one variable causes startup to fail.

With default bridge networking, `127.0.0.1` refers to the Nginx container itself.
When using a hostname, configure a working `resolver` in the Nginx `http` context.

## Configuration files

To manage the configuration yourself, mount your configuration file read-only at
`/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf` and leave both environment variables unset.

```sh
docker run -d \
  --name nginx-crowdsec-bouncer \
  -p 8080:80 \
  -v "$PWD/crowdsec-nginx-bouncer.conf:/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf:ro" \
  henry42/nginx-crowdsec-bouncer
```

You can also mount `/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.local` to override
individual settings; the bouncer gives these values precedence. This optional file
is not included in the image or generated at startup. Create it yourself on the host
and mount it into the container. If it is absent, the bouncer uses the main configuration.

Mount custom Nginx server or reverse proxy configuration files under `/etc/nginx/http.d/`.
If you replace `/etc/nginx/nginx.conf`, include that directory inside its `http` block.

## CAPTCHA (optional)

If you do not need CAPTCHA, leave `SITE_KEY` and `SECRET_KEY` empty. The upstream
library still attempts to initialize CAPTCHA and logs this message at startup:

```text
error loading captcha plugin: no recaptcha site key provided, can't use recaptcha
```

This message alone does not stop Nginx from starting or disable normal ban
remediation. With the default `FALLBACK_REMEDIATION=ban`, CAPTCHA decisions fall
back to blocking the request.

To enable CAPTCHA, obtain a matching site key and secret key from your CAPTCHA
provider, then create `crowdsec-nginx-bouncer.conf.local` on the host with the command
below. Replace the placeholder keys with your own values. These keys are separate
from your CrowdSec `API_KEY`:

```sh
cat > crowdsec-nginx-bouncer.conf.local <<'EOF'
CAPTCHA_PROVIDER=recaptcha
SITE_KEY=your-captcha-site-key
SECRET_KEY=your-captcha-secret-key
EOF
```

Supported providers are `recaptcha`, `hcaptcha`, and `turnstile`. Configure these
settings in the file; the image does not read them from environment variables.
Add this mount to your `docker run` command and recreate the container:

```sh
-v "$PWD/crowdsec-nginx-bouncer.conf.local:/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.local:ro"
```

Set both keys together. Leaving either key empty logs a CAPTCHA initialization error.
See the [upstream documentation](https://docs.crowdsec.net/u/bouncers/nginx/) for more options.

## Logs

By default, access logs go to standard output and error logs go to standard error.

```sh
docker logs -f nginx-crowdsec-bouncer
```
