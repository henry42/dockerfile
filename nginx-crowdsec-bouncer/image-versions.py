#!/usr/bin/env python3
"""Read component versions from the exact multi-platform image built by CI."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


# Bypass the runtime entrypoint: no endpoint or API key is needed for inspection.
PROBE = r"""
printf 'ALPINE_VERSION=%s\n' "$(cat /etc/alpine-release)"
awk -F: '
    $1 == "P" { package = substr($0, 3) }
    $1 == "V" && package == "nginx" {
        print "NGINX_VERSION=" substr($0, 3)
        matches++
    }
    END { if (matches != 1) exit 1 }
' /lib/apk/db/installed
sed -n 's|.*"crowdsec-nginx-bouncer/v\([0-9][0-9.]*\)".*|BOUNCER_VERSION=\1|p' \
    /etc/nginx/http.d/crowdsec_nginx.conf
"""

PATTERNS = {
    "NGINX_VERSION": r"[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+",
    "ALPINE_VERSION": r"[0-9]+\.[0-9]+\.[0-9]+",
    "BOUNCER_VERSION": r"[0-9]+\.[0-9]+\.[0-9]+",
}


def read_versions(image, platform):
    result = subprocess.run(
        ["docker", "run", "--rm", "--pull=always", "--platform", platform, "--entrypoint", "sh", image, "-ec", PROBE],
        text=True, capture_output=True, check=True,
    )
    versions = {}
    for line in result.stdout.splitlines():
        name, separator, value = line.partition("=")
        if not separator or name not in PATTERNS or name in versions:
            raise ValueError(f"Unexpected or duplicate version output on {platform}: {line!r}")
        if not re.fullmatch(PATTERNS[name], value):
            raise ValueError(f"Invalid {name} on {platform}: {value!r}")
        versions[name] = value
    if versions.keys() != PATTERNS.keys():
        raise ValueError(f"Incomplete component versions on {platform}")
    print(json.dumps({"platform": platform, **versions}), flush=True)
    return versions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("amd64_image", help="Docker Hub repository@sha256:digest for the amd64 manifest")
    parser.add_argument("arm64_image", help="Docker Hub repository@sha256:digest for the arm64 manifest")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    if not all(re.search(r"@sha256:[0-9a-f]{64}$", image) for image in (args.amd64_image, args.arm64_image)):
        parser.error("Provide both platform images by digest")
    try:
        versions = read_versions(args.amd64_image, "linux/amd64")
        if read_versions(args.arm64_image, "linux/arm64") != versions:
            raise ValueError("amd64 and arm64 component versions differ; refusing to publish a misleading tag")
    except (ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        return 1
    tag = "nginx{NGINX_VERSION}-alpine{ALPINE_VERSION}-bouncer{BOUNCER_VERSION}".format(**versions)
    if len(tag) > 128:
        parser.error("Component tag exceeds Docker's 128-character limit")
    print(json.dumps({"tag": tag, **versions}, indent=2))
    if args.github_output:
        with args.github_output.open("a") as output:
            output.write(f"tag={tag}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
