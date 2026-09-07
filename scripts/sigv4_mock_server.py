#!/usr/bin/env python3
"""
Minimal mock REST catalog server for testing SigV4 HTTP scheme handling.
Accepts any request with SigV4 Authorization header and returns valid Iceberg REST responses.

Usage:
    python3 sigv4_mock_server.py [port] [--fail-first N]
    Default port: 19130
"""

import argparse
import json
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler


class MockCatalogHandler(BaseHTTPRequestHandler):
    # Answer this many GET requests with a 502 before serving normally, so a client's
    # retry behaviour on a transient gateway failure can be observed. Zero unless
    # --fail-first is passed: every other test using this server sees no change.
    fail_first = 0

    def do_GET(self):
        if MockCatalogHandler.fail_first > 0:
            MockCatalogHandler.fail_first -= 1
            self._respond(502, {"message": "Bad Gateway"})
            return

        # Check for SigV4 Authorization header
        auth = self.headers.get("Authorization", "")
        has_sigv4 = auth.startswith("AWS4-HMAC-SHA256")

        if self.path.startswith("/v1/config"):
            self._respond(200, {"defaults": {}, "overrides": {}})
        elif "/namespaces" in self.path:
            self._respond(200, {"namespaces": []})
        else:
            self._respond(200, {})

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()

    def do_POST(self):
        self._respond(200, {})

    def _respond(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        # Suppress default logging
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", nargs="?", type=int, default=19130)
    parser.add_argument(
        "--fail-first",
        type=int,
        default=0,
        metavar="N",
        help="answer the first N GET requests with HTTP 502",
    )
    args = parser.parse_args()

    MockCatalogHandler.fail_first = args.fail_first
    port = args.port
    server = HTTPServer(("127.0.0.1", port), MockCatalogHandler)
    print(f"Mock SigV4 catalog server listening on http://127.0.0.1:{port}")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
