#!/usr/bin/env python3
"""Serve the web export with cross-origin-isolation headers.

Threaded Godot web builds need SharedArrayBuffer, which browsers gate on
TWO things:
  1. COOP/COEP headers on every response (plain `python3 -m http.server`
     won't cut it — this script sends them).
  2. A secure context. localhost qualifies over plain http; a phone
     hitting a LAN IP does NOT.

So for phone testing over wifi you want --https, which mints a self-signed
cert for THIS machine's current LAN IP (accept the warning once on the
device). Android users with a USB cable can skip TLS entirely via
`adb reverse tcp:PORT tcp:PORT` and open http://localhost:PORT instead —
but that is Android-only, so --https is the general answer.

Binds 0.0.0.0 so LAN devices can connect.

    python3 scripts/dev/serve_web.py [port] [dir] [--https] [--ip LAN_IP]

Defaults: port 8060 (8061 with --https), dir build/web, and the LAN IP is
auto-detected — pass --ip only to override a bad guess (multiple adapters,
VPN, etc).
"""

import argparse
import http.server
import os
import socket
import ssl
import subprocess

CERT_DIR = "/tmp/vibezcraft-tls"


class COIHandler(http.server.SimpleHTTPRequestHandler):
    # Explicit wasm MIME so browsers take the streaming-compile path.
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
    }

    # Keep-alive. The default HTTP/1.0 closes the connection after every
    # response, and a Godot export is ~40 MB across a burst of parallel
    # requests (engine js/wasm, the pck, the GDExtension side module, and
    # one js fetch per worker thread). Under that load the 1.0 path wedged
    # the server outright: the process stayed alive but every subsequent
    # request — including plain index.html — returned an empty response,
    # which reads exactly like a corrupt build (the browser reports the
    # side module as ERR_EMPTY_RESPONSE and Emscripten then hangs forever
    # on `loadDylibs`). Phones make this worse, not better: more latency,
    # more parallelism, more aborted transfers.
    protocol_version = "HTTP/1.1"

    def copyfile(self, source, outputfile):
        # A client that navigates away, backgrounds the tab, or aborts a
        # range request mid-transfer is completely normal here — Emscripten
        # does it during startup. Don't let it surface as a traceback.
        try:
            super().copyfile(source, outputfile)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        # no-store on purpose: a cached pck silently serves yesterday's
        # build, which is a genuinely hard bug to spot on a device. Costs a
        # full re-download per reload — that is the intended trade.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def _default_route_ip():
    """Address of the interface the default route uses. connect() on a UDP
    socket sends nothing, so this works offline and cross-platform."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except OSError:
        return None
    finally:
        sock.close()


def detect_lan_ips():
    """Every non-loopback IPv4 this machine answers on, default route first.

    Deliberately a LIST, not a single best guess. A laptop docked to
    ethernet while also on wifi has two addresses on the same subnet, and
    the default route is usually the ethernet one — while the phone you are
    testing from is on wifi. Picking one guesses wrong half the time, so
    every address goes in the cert SAN and every URL gets printed.
    """
    ips = []
    primary = _default_route_ip()
    if primary:
        ips.append(primary)
    try:
        # macOS / BSD. Linux `ip -4 addr` is handled by the same parse since
        # we only look for "inet <addr>" tokens.
        out = subprocess.run(
            ["ifconfig"], capture_output=True, text=True, check=True
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        try:
            out = subprocess.run(
                ["ip", "-4", "addr"], capture_output=True, text=True, check=True
            ).stdout
        except (subprocess.CalledProcessError, FileNotFoundError):
            out = ""
    words = out.split()
    for i, word in enumerate(words):
        if word == "inet" and i + 1 < len(words):
            addr = words[i + 1].split("/")[0]
            if addr.startswith("127.") or addr in ips:
                continue
            if addr.count(".") == 3:
                ips.append(addr)
    return ips or ["127.0.0.1"]


def cert_matches(cert, host_ips):
    """True when an existing cert covers every host_ip and is still valid.

    The previous version only checked that the files EXISTED, so the day
    your DHCP lease moved you kept serving a cert for the old address and
    the phone rejected it — with a TLS error that looks like a network
    fault rather than a stale cert."""
    try:
        san = subprocess.run(
            ["openssl", "x509", "-in", cert, "-noout", "-ext", "subjectAltName"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False
    if any("IP Address:%s" % ip not in san for ip in host_ips):
        return False
    expired = subprocess.run(
        ["openssl", "x509", "-in", cert, "-noout", "-checkend", "86400"],
        capture_output=True,
    )
    return expired.returncode == 0


def ensure_cert(host_ips):
    cert = os.path.join(CERT_DIR, "cert.pem")
    key = os.path.join(CERT_DIR, "key.pem")
    have = os.path.exists(cert) and os.path.exists(key)
    if have and cert_matches(cert, host_ips):
        return cert, key
    if have:
        print("  cert did not cover %s (or expired) — regenerating"
              % ", ".join(host_ips), flush=True)
    os.makedirs(CERT_DIR, exist_ok=True)
    san = ",".join("IP:%s" % ip for ip in host_ips) + ",DNS:localhost"
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", key, "-out", cert, "-days", "30", "-nodes",
            "-subj", "/CN=%s" % host_ips[0],
            "-addext", "subjectAltName=%s" % san,
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
    parser.add_argument(
        "--ip",
        default=None,
        help="LAN IP to serve (default: every detected address goes in the cert)",
    )
    args = parser.parse_args()
    port = args.port if args.port is not None else (8061 if args.https else 8060)
    host_ips = [args.ip] if args.ip else detect_lan_ips()

    os.chdir(args.directory)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", port), COIHandler)
    server.daemon_threads = True
    scheme = "http"
    if args.https:
        cert, key = ensure_cert(host_ips)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        scheme = "https"

    print("serving %s (COOP/COEP on)" % args.directory, flush=True)
    print("  this machine : %s://localhost:%d/index.html" % (scheme, port), flush=True)
    print("  on your phone (try these, same wifi):", flush=True)
    for ip in host_ips:
        print("    %s://%s:%d/index.html" % (scheme, ip, port), flush=True)
    if args.https:
        print("  (accept the self-signed cert warning once on the device)", flush=True)
    else:
        print(
            "  NOTE: plain http over a LAN IP is not a secure context, so a phone\n"
            "        gets no SharedArrayBuffer and this threaded build will not boot.\n"
            "        Re-run with --https for device testing.",
            flush=True,
        )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped", flush=True)


if __name__ == "__main__":
    main()
