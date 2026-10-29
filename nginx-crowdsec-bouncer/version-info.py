#!/usr/bin/env python3
"""Resolve CI inputs from the Dockerfile defaults, without duplicating versions."""
import argparse
import json
from pathlib import Path
import re


def resolve(args):
    root = Path(__file__).resolve().parent
    defaults = dict(re.findall(r"^ARG ([A-Z_]+)=([^\s]+)$", (root / "Dockerfile").read_text(), re.M))
    versions = {}
    for name, pattern in (
        ("NGINX_VERSION", r"[0-9]+\.[0-9]+\.[0-9]+"),
        ("ALPINE_VERSION", r"[0-9]+\.[0-9]+"),
        ("BOUNCER_VERSION", r"[0-9]+\.[0-9]+\.[0-9]+"),
    ):
        value = getattr(args, name.lower()) or defaults[name]
        if not re.fullmatch(pattern, value):
            raise ValueError(f"Invalid {name}: expected a fixed numeric release version")
        versions[name] = value
    digest = args.nginx_image_digest or defaults["NGINX_IMAGE_DIGEST"]
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("NGINX_IMAGE_DIGEST must be a fixed sha256 manifest digest")
    if any(versions[n] != defaults[n] for n in ("NGINX_VERSION", "ALPINE_VERSION")) and not args.nginx_image_digest:
        raise ValueError("Changing Nginx/Alpine requires the matching official NGINX_IMAGE_DIGEST")
    lock = (root / "source-checksums.sha256").read_text()
    for archive in (
        f"nginx-{versions['NGINX_VERSION']}.tar.gz",
        f"crowdsec-nginx-bouncer-{versions['BOUNCER_VERSION']}.tgz",
    ):
        if not re.search(r"^[0-9a-f]{64}  " + re.escape(archive) + r"$", lock, re.M):
            raise ValueError(f"Review and add {archive} to source-checksums.sha256 first")
    n, a, b = (versions[name] for name in ("NGINX_VERSION", "ALPINE_VERSION", "BOUNCER_VERSION"))
    return {
        **versions,
        "NGINX_IMAGE_DIGEST": digest,
        "tag": f"nginx-{n}-alpine-{a}-bouncer-{b}",
        "compact_tag": f"nginx{n}-alpine{a}-bouncer{b}",
        "build_args": "\n".join(f"{key}={value}" for key, value in {**versions, "NGINX_IMAGE_DIGEST": digest}.items()),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("nginx-version", "alpine-version", "bouncer-version", "nginx-image-digest"):
        parser.add_argument("--" + name, default="")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    try:
        result = resolve(args)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2))
    if args.github_output:
        with args.github_output.open("a") as output:
            for name in ("tag", "compact_tag"):
                output.write(f"{name}={result[name]}\n")
            output.write("build_args<<BUILD_ARGS\n" + result["build_args"] + "\nBUILD_ARGS\n")


if __name__ == "__main__":
    main()
