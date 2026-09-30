"""Tiny HTTP server that echoes the request back as JSON.

Usage: python3 echo_server.py

Binds a free port and prints it on stdout once ready.
"""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Echo(BaseHTTPRequestHandler):
    def _echo(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        if self.path.startswith("/status/"):
            code = int(self.path.split("/")[2])
        else:
            code = 200
        payload = json.dumps(
            {
                "method": self.command,
                "path": self.path,
                "version": self.request_version,
                "headers": {k.lower(): v for k, v in self.headers.items()},
                "body": body,
            }
        ).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _echo

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Echo)
    print(server.server_address[1], flush=True)
    server.serve_forever()
