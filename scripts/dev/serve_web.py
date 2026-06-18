#!/usr/bin/env python3
"""Serve the web export with cross-origin-isolation headers.

Threaded Godot web builds need SharedArrayBuffer, which browsers gate on
TWO things:
  1. COOP/COEP headers on every response (plain `python3 -m http.server`
     won't cut it — this script sends them).
  2. A secure context. localhost qualifies over plain http; a phone
     hitting a LAN IP does NOT, so for device testing either run with
     --https (self-signed cert auto-generated into /tmp via openssl;
     accept the browser warning once on the phone) or use
     `adb reverse tcp:PORT tcp:PORT` and open http://localhost:PORT
     on the device.

Binds 0.0.0.0 so LAN devices can connect.

    python3 scripts/dev/serve_web.py [port] [dir] [--https] [--ip LAN_IP]

Defaults: port 8060 (8061 with --https), dir build/web.
"""

import argparse
import http.server
import os
import ssl
import subprocess

CERT_DIR = "/tmp/vibezcraft-tls"


class COIHandler(http.server.SimpleHTTPRequestHandler):
    # Explicit wasm MIME so browsers take the streaming-compile path.
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
    }

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def ensure_cert(host_ip):
    cert = os.path.join(CERT_DIR, "cert.pem")
    key = os.path.join(CERT_DIR, "key.pem")
    if not (os.path.exists(cert) and os.path.exists(key)):
        os.makedirs(CERT_DIR, exist_ok=True)
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", key, "-out", cert, "-days", "30", "-nodes",
                "-subj", "/CN=%s" % host_ip,
                "-addext", "subjectAltName=IP:%s,DNS:localhost" % host_ip,
            ],
            check=True,
            capture_output=True,
        )
    return cert, key


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("port", nargs="?", type=int, default=None)
    parser.add_argument("directory", nargs="?", default="build/web")
    parser.add_argument("--https", action="store_true")
    parser.add_argument("--ip", default="192.168.1.43", help="LAN IP baked into the cert SAN")
    args = parser.parse_args()
    port = args.port if args.port is not None else (8061 if args.https else 8060)

    os.chdir(args.directory)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", port), COIHandler)
    scheme = "http"
    if args.https:
        cert, key = ensure_cert(args.ip)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        scheme = "https"
    print(
        "serving %s at %s://%s:%d (COOP/COEP on)" % (args.directory, scheme, args.ip, port),
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
