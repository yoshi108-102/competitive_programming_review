"""
CORS lab server.

CORS_MODE=none|wildcard|exact|wrong|credentials-bug|full python server.py

Frontend is expected to run on http://localhost:5500 (different origin).
This server runs on http://localhost:8000.
"""

import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8000
FRONT_ORIGIN = "http://localhost:5500"
MODE = os.environ.get("CORS_MODE", "none")

VALID_MODES = {"none", "wildcard", "exact", "wrong", "credentials-bug", "full"}

# Always-permissive headers used by /healthz, regardless of CORS_MODE.
HEALTHZ_HEADERS: dict[str, str] = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "*",
    "Access-Control-Max-Age": "60",
}


def cors_headers(request_origin: str | None) -> dict[str, str]:
    """Return CORS response headers based on the current mode."""
    h: dict[str, str] = {}
    if MODE == "none":
        return h
    if MODE == "wildcard":
        h["Access-Control-Allow-Origin"] = "*"
    elif MODE == "exact":
        h["Access-Control-Allow-Origin"] = FRONT_ORIGIN
    elif MODE == "wrong":
        h["Access-Control-Allow-Origin"] = "http://example.com"
    elif MODE == "credentials-bug":
        # Browsers reject `*` + credentials=true. This is the canonical mistake.
        h["Access-Control-Allow-Origin"] = "*"
        h["Access-Control-Allow-Credentials"] = "true"
    elif MODE == "full":
        h["Access-Control-Allow-Origin"] = FRONT_ORIGIN
        h["Access-Control-Allow-Credentials"] = "true"
        h["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        h["Access-Control-Allow-Headers"] = "Content-Type, X-My-Header"
        h["Vary"] = "Origin"
    return h


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:  # silence default noisy log
        return

    def handle_one_request(self) -> None:
        # Log TCP-level arrival BEFORE dispatch, so we can tell whether
        # "Failed to fetch" means "TCP never arrived" vs. "arrived but CORS-rejected".
        try:
            # Peek at the request line without consuming it; fall back to default.
            super().handle_one_request()
        finally:
            # client_address and the parsed command/path are populated by
            # parse_request() inside handle_one_request, so we log after.
            try:
                client = f"{self.client_address[0]}:{self.client_address[1]}"
            except Exception:
                client = "?"
            cmd = getattr(self, "command", "?") or "?"
            path = getattr(self, "path", "?") or "?"
            print(f"[wire] client={client} {cmd} {path}", flush=True)

    def _log(self, extra: str = "") -> None:
        origin = self.headers.get("Origin", "-")
        custom = "yes" if self.headers.get("X-My-Header") else "no"
        print(
            f"[mode={MODE}] {self.command} {self.path} "
            f"origin={origin} has-custom-header={custom} {extra}",
            flush=True,
        )

    def _write(
        self,
        status: int,
        body: bytes,
        content_type: str = "application/json",
        headers: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        hdrs = headers if headers is not None else cors_headers(self.headers.get("Origin"))
        for k, v in hdrs.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ---- /healthz: control endpoint, ALWAYS permissive ----
    def _is_healthz(self) -> bool:
        return self.path.split("?", 1)[0] == "/healthz"

    def _healthz_get(self) -> None:
        body = b'{"ok":true,"endpoint":"healthz"}'
        self._write(200, body, headers=HEALTHZ_HEADERS)

    def _healthz_options(self) -> None:
        self.send_response(204)
        for k, v in HEALTHZ_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()

    def do_OPTIONS(self) -> None:
        if self._is_healthz():
            self._log("(healthz preflight)")
            self._healthz_options()
            return
        self._log("(preflight)")
        # 204 No Content. If MODE=none, no CORS headers are added -> preflight fails.
        self.send_response(204)
        for k, v in cors_headers(self.headers.get("Origin")).items():
            self.send_header(k, v)
        self.end_headers()

    def do_GET(self) -> None:
        if self._is_healthz():
            self._log("(healthz)")
            self._healthz_get()
            return
        self._log()
        self._write(200, b'{"ok":true,"method":"GET"}')

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length else b""
        # Loud log: handler reached => server-side side-effect would happen
        # even if the browser later refuses to expose the response.
        print(
            f"  >>> POST RECEIVED (side-effect would fire) "
            f"bytes={len(body)} body={body[:120]!r}",
            flush=True,
        )
        self._log()
        self._write(200, b'{"ok":true,"method":"POST"}')


class DualStackServer(HTTPServer):
    # Browsers resolve `localhost` to ::1 first on macOS, so an IPv4-only
    # bind shows up as "Failed to fetch" before CORS even comes into play.
    address_family = socket.AF_INET6

    def server_bind(self) -> None:
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def main() -> None:
    if MODE not in VALID_MODES:
        print(f"unknown CORS_MODE={MODE!r}; valid: {sorted(VALID_MODES)}", file=sys.stderr)
        sys.exit(2)
    print(f"cors-lab server on http://localhost:{PORT}  CORS_MODE={MODE}")
    print(f"Listening on [::]:{PORT} (IPv6 dual-stack)")
    print(f"front origin assumed: {FRONT_ORIGIN}")
    print("control endpoint: /healthz (always permissive, mode-independent)")
    DualStackServer(("::", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
