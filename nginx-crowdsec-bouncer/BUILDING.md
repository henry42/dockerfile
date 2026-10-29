# Building and publishing

## Version policy

`Dockerfile` ARG defaults are the single source of version defaults:

| Input | Default |
| --- | --- |
| `NGINX_VERSION` | `1.31.8` |
| `ALPINE_VERSION` | `3.24` |
| `BOUNCER_VERSION` | `1.2.3` (upstream `v1.2.3`, including `lua-cs-bouncer v1.0.19`) |
| `NGINX_IMAGE_DIGEST` | The exact official multi-architecture manifest digest in Dockerfile. |

The official tag is `nginx:1.31.8-alpine3.24`. Official Alpine tags use the Alpine
series rather than a patch release; the additional manifest digest fixes the actual
base filesystem. Builder and runtime derive from the same named official image stage.
No Nginx executable is rebuilt or replaced. The build verifies the actual Nginx
version and Alpine series before compiling modules.

`install.sh` uses the same Nginx version's source, the actual `nginx -V` configure
arguments and `--with-compat`, then runs `make modules`. This preserves the official
binary and its hardening options. Runtime runs `nginx -t` and `nginx -V` during the
build. Every supported architecture must pass the module load check.

Additional dependencies are pinned in Dockerfile: Lua module `0.10.31`, NDK `0.3.4`,
OpenResty's LuaJIT fork `2.1-20261023`, resty-lrucache `0.15`, resty-http `0.18.0`,
resty-string `0.19`, resty-openssl `1.9.0` and lua-cjson `2.1.0.20`. resty-string is
required by resty-http; resty-openssl retains its mTLS support. Using the LuaJIT fork
does not replace the official Nginx
distribution with OpenResty. resty-core is pinned to commit
`6fec23e2149c88b33b39fec8a5ebdd67a3e0dd88` (`v0.1.34rc3`), whose explicit ABI check
matches Lua module `0.10.31`. The latest stable resty-core tag `0.1.32` requires
Lua module `0.10.29`, so those tags cannot be mixed. Do not weaken this compatibility
check to make arbitrary versions load.

`source-checksums.sha256` locks every downloaded archive. The bouncer digest matches
the official GitHub release asset digest. Its bundled Lua library is used together
with that release's configuration; it is not replaced by a default Git branch.
The existing vendored bouncer archive is reused only for the matching version and
must pass the same checksum. Upstream host installers are never executed.

Alpine build/runtime packages come from the fixed Alpine series repositories and
can receive updates. Source/base pinning does not promise bit-for-bit identical
output across different toolchain repository states. Build logs and image provenance
should be retained for audits.

## Local build

From the repository root:

```sh
docker build \
  --build-arg NGINX_VERSION=1.31.8 \
  --build-arg ALPINE_VERSION=3.24 \
  --build-arg BOUNCER_VERSION=1.2.3 \
  -t henry42/nginx-crowdsec-bouncer:nginx1.31.8-alpine3.24-bouncer1.2.3 \
  ./nginx-crowdsec-bouncer
```

The matching digest defaults to Dockerfile. No BuildKit-only COPY flags or cache
mounts are required. Compilers, headers, source trees and download tools stay in
the builder; the final image receives only modules, Lua files and configuration.
Never supply API keys during a build. Runtime configuration is rendered on startup.

When updating Nginx or Alpine, update the default versions and the official manifest
digest together. Review the new Nginx source checksum. Changing a bouncer or Lua
dependency requires its archive checksum too. The checksum lock intentionally rejects
unreviewed versions. There is no artificial Nginx/OpenResty release-series restriction;
new official Nginx releases can be evaluated immediately with the module load and
request tests. Actual upstream Lua source compatibility still has to be tested.

## GitHub Actions

Push a Git tag in this exact format to build and publish:

```text
nginx<nginx-version>-alpine<alpine-version>-bouncer<bouncer-version>
```

For example:

```sh
git tag nginx1.31.8-alpine3.24-bouncer1.2.3
git push origin nginx1.31.8-alpine3.24-bouncer1.2.3
```

`publish-nginx-crowdsec-bouncer.yml` matches `nginx*-alpine*-bouncer*` pushes.
`version-info.py` then strictly validates the format and derives `NGINX_VERSION`,
`ALPINE_VERSION` and `BOUNCER_VERSION` from the tag. Those values become explicit
Docker build arguments. Docker Hub receives the exact same tag:

```text
henry42/nginx-crowdsec-bouncer:nginx1.31.8-alpine3.24-bouncer1.2.3
```

The component tag is the primary image tag. Existing commit-SHA tags, manual-main
`edge` aliases and PR metadata remain available. Other image callers retain their
existing SemVer/alias behavior.

Before pushing a new release tag, update the reviewed Dockerfile base-version/digest
pins and source checksums as described above. A tag cannot silently reuse a base
image for a different Nginx/Alpine version or bypass the source checksum lock.
No component-version defaults are duplicated in workflow YAML. Logs show the three
selected versions and the base digest.

Manual dispatch still exposes the three version inputs and base image digest.
On `main`, empty inputs use Dockerfile defaults. When selecting a release tag,
versions come from that tag and conflicting manual inputs are rejected. Changing
Nginx/Alpine through manual inputs requires a matching explicit digest.

The workflow serializes this image's publishes and refuses to overwrite an existing
component tag. Enable Docker Hub's immutable-tag policy for this tag pattern to
enforce immutability against publishers outside this workflow as well.

Pull requests build/verify without pushing. Publishing still uses the existing
`DockerHub` environment credentials and `linux/amd64,linux/arm64` platforms. The
shared workflow's new inputs default to empty/false, preserving other image callers.

## Verification

On a Linux Docker host, after building:

```sh
python3 nginx-crowdsec-bouncer/verify.py \
  henry42/nginx-crowdsec-bouncer:nginx1.31.8-alpine3.24-bouncer1.2.3
```

The same verification runs in CI before publishing. It checks `nginx -t`, `nginx -V`,
unchanged official Nginx binary, Lua execution over HTTP, LAPI-only operation and
ban enforcement, the legacy endpoint alias, secret-file and read-only mounted config
modes, AppSec request/body forwarding, AppSec blocking, fail-open with AppSec
unreachable, restart/secret rotation and image metadata/configuration for baked keys.
It starts temporary Python protocol mocks on the runner, not additional production
containers or CrowdSec engines. These mocks validate the client integration, not
actual WAF rule effectiveness; real-host `cscli metrics show appsec` validation is
described in README.

Image checks can also be inspected manually:

```sh
docker history --no-trunc henry42/nginx-crowdsec-bouncer:nginx1.31.8-alpine3.24-bouncer1.2.3
docker image inspect henry42/nginx-crowdsec-bouncer:nginx1.31.8-alpine3.24-bouncer1.2.3
```
