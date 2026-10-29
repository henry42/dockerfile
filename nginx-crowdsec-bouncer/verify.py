#!/usr/bin/env python3
"""Verify a built image against temporary protocol mocks, without CrowdSec engines.

Run on a Linux Docker host: python3 verify.py IMAGE
Real WAF rule validation still requires the host's CrowdSec AppSec metrics.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen
import uuid


def docker(*args, check=True):
    result = subprocess.run(["docker", *args], text=True, capture_output=True, check=check)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    image = parser.parse_args().image
    info = json.loads(docker("image", "inspect", image))[0]
    key = "verification-" + uuid.uuid4().hex
    history = docker("history", "--no-trunc", image)
    assert key not in history and key not in json.dumps(info), "Runtime key found in image metadata"
    assert not any(item.startswith("API_KEY=") for item in info["Config"].get("Env", [])), "Baked API_KEY environment variable"
    docker("run", "--rm", "--entrypoint", "sh", image, "-ec",
           "! grep -Eq '^API_KEY=.+$' /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf*")
    for command in (("nginx", "-t"), ("nginx", "-V")):
        result = subprocess.run(["docker", "run", "--rm", image, *command], text=True, capture_output=True, check=True)
        print(result.stdout + result.stderr)
    labels = info["Config"]["Labels"]
    base = labels["org.opencontainers.image.base.name"] + "@" + labels["org.opencontainers.image.base.digest"]
    assert docker("run", "--rm", "--entrypoint", "sha256sum", image, "/usr/sbin/nginx") == docker(
        "run", "--rm", "--entrypoint", "sha256sum", base, "/usr/sbin/nginx"
    ), "Official Nginx executable was changed"
    print("Official Nginx binary unchanged; no build-time key in image metadata/configuration.")

    state = {"key": key, "ban": False, "lapi": 0, "appsec": []}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.handle_request()

        def do_POST(self):
            self.handle_request()

        def handle_request(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            status, response = 200, None
            if self.path.startswith("/lapi/"):
                if self.headers.get("x-api-key") != state["key"]:
                    status = 401
                else:
                    state["lapi"] += 1
                    if state["ban"]:
                        ip = parse_qs(urlparse(self.path).query)["ip"][0]
                        response = [{"type": "ban", "origin": "cscli", "value": ip, "scope": "ip", "duration": "1m"}]
            elif self.path == "/appsec":
                if self.headers.get("x-crowdsec-appsec-api-key") != state["key"]:
                    status = 401
                else:
                    uri = self.headers.get("x-crowdsec-appsec-uri", "")
                    state["appsec"].append((uri, body, self.headers.get("x-crowdsec-appsec-verb")))
                    if uri == "/blocked-by-appsec":
                        status, response = 403, {"action": "ban", "http_status": 403}
            else:
                status = 404
            payload = json.dumps(response).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    lapi = ThreadingHTTPServer(("0.0.0.0", 0), Handler)
    appsec = ThreadingHTTPServer(("0.0.0.0", 0), Handler)
    for server in (lapi, appsec):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    containers = []
    try:
        with tempfile.TemporaryDirectory(prefix="crowdsec-image-verification-") as directory:
            root = Path(directory)
            server_config = root / "default.conf"
            server_config.write_text("""server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    location = /lua-proof {
        access_by_lua_block { }
        content_by_lua_block { ngx.say(ngx.config.ngx_lua_version) }
    }
    location / {
        content_by_lua_block { ngx.say("ok") }
    }
}
""")
            secret = root / "api-key"
            secret.write_text(key + "\n")
            lapi_url = f"http://crowdsec-host:{lapi.server_port}/lapi"
            appsec_url = f"http://crowdsec-host:{appsec.server_port}/appsec"

            def start(settings, mounts=()):
                args = ["run", "-d", "--add-host", "crowdsec-host:host-gateway", "-p", "127.0.0.1::80",
                        "-v", f"{server_config}:/etc/nginx/conf.d/default.conf:ro",
                        "-v", f"{secret}:/run/secrets/crowdsec_api_key:ro"]
                for mount in mounts:
                    args += ["-v", mount]
                for name, value in settings.items():
                    args += ["-e", name + "=" + value]
                container = docker(*args, image)
                containers.append(container)
                inspect = json.loads(docker("inspect", container))[0]
                port = inspect["NetworkSettings"]["Ports"]["80/tcp"][0]["HostPort"]
                url = "http://127.0.0.1:" + port
                for _ in range(80):
                    try:
                        with urlopen(url + "/lua-proof", timeout=1) as response:
                            assert response.read().strip().isdigit(), "Lua module did not execute"
                            return container, url
                    except (URLError, TimeoutError, ConnectionError):
                        if docker("inspect", "--format", "{{.State.Running}}", container) != "true":
                            raise AssertionError(docker("logs", container))
                        time.sleep(0.25)
                raise AssertionError("Nginx startup timeout: " + docker("logs", container))

            def request(url, path, expected=200, body=None):
                req = Request(url + path, data=body)
                try:
                    with urlopen(req, timeout=5) as response:
                        status = response.status
                except HTTPError as error:
                    status = error.code
                assert status == expected, (path, status, expected)

            def stop(container):
                logs = docker("logs", container)
                assert not re.search(r"not binary compatible|unknown directive|undefined symbol|error while loading shared libraries|failed to load the .resty.core. module|module .+ not found", logs), logs
                docker("rm", "-f", container)
                containers.remove(container)

            container, url = start({"API_URL": lapi_url, "API_KEY_FILE": "/run/secrets/crowdsec_api_key"})
            request(url, "/")
            assert state["lapi"] > 0
            state["ban"] = True
            time.sleep(1.2)  # Upstream live-mode decision cache expires after one second.
            request(url, "/blocked-by-lapi", 403)
            stop(container)
            state["ban"] = False
            print("LAPI-only mode, Docker secret and IP ban enforcement passed.")

            previous_lapi_requests = state["lapi"]
            container, url = start({"CROWDSEC_LAPI_URL": lapi_url, "API_KEY": key})
            request(url, "/")
            assert state["lapi"] > previous_lapi_requests, "Legacy endpoint did not authenticate with LAPI"
            stop(container)
            print("Legacy CROWDSEC_LAPI_URL/API_KEY configuration passed.")

            gateway = json.loads(docker("network", "inspect", "bridge"))[0]["IPAM"]["Config"][0]["Gateway"]
            mounted = root / "mounted.conf"
            template = docker("run", "--rm", "--entrypoint", "cat", image,
                              "/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf.example")
            template = re.sub(r"^API_URL=.*$", "API_URL=" + lapi_url.replace("crowdsec-host", gateway), template, flags=re.M)
            template = re.sub(r"^API_KEY=.*$", "API_KEY=" + key, template, flags=re.M)
            mounted.write_text(template + "\n")
            previous_lapi_requests = state["lapi"]
            container, url = start({}, [f"{mounted}:/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf:ro"])
            request(url, "/")
            assert state["lapi"] > previous_lapi_requests, "Mounted configuration did not authenticate with LAPI"
            assert mounted.read_text() == template + "\n"
            stop(container)
            print("Read-only mounted configuration passed.")

            container, url = start({"API_URL": lapi_url, "API_KEY_FILE": "/run/secrets/crowdsec_api_key",
                                    "APPSEC_URL": appsec_url, "APPSEC_FAILURE_ACTION": "passthrough",
                                    "APPSEC_DROP_UNREADABLE_BODY": "false"})
            request(url, "/allowed")
            request(url, "/body", body=b"field=value")
            assert ("/body", b"field=value", "POST") in state["appsec"]
            request(url, "/blocked-by-appsec", 403)
            assert any(row[0] == "/blocked-by-appsec" for row in state["appsec"])
            print("AppSec forwarding, body forwarding and AppSec block enforcement passed.")

            appsec.shutdown()
            appsec.server_close()
            request(url, "/appsec-unavailable")
            print("AppSec unreachable with passthrough: website still returns HTTP 200.")

            # Restart must render a fresh file and reread the secret without appending.
            state["key"] = "rotated-" + uuid.uuid4().hex
            secret.write_text(state["key"] + "\n")
            previous_lapi_requests = state["lapi"]
            docker("restart", container)
            for _ in range(80):
                try:
                    request(url, "/after-restart")
                    if state["lapi"] > previous_lapi_requests:
                        break
                    time.sleep(0.25)
                except (URLError, ConnectionError, TimeoutError):
                    time.sleep(0.25)
            else:
                raise AssertionError("Nginx did not recover after restart")
            assert docker("exec", container, "sh", "-ec",
                          "grep -c '^API_KEY=' /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf") == "1"
            stop(container)
            print("Restart and secret rotation passed. All image verifications passed.")
    finally:
        for container in containers:
            docker("rm", "-f", container, check=False)
        for server in (lapi, appsec):
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
