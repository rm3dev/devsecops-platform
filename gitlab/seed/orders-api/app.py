"""orders-api - the platform's sample microservice (Python stdlib only).

Endpoints:
  GET /healthz  liveness + startup probe target (chart: probes.liveness/startup)
  GET /readyz   readiness probe target          (chart: probes.readiness)
  GET /orders   tiny JSON payload for smoke tests

Config (rendered into the ConfigMap by helm-charts/microservice-standard):
  HTTP_PORT   listen port                       (default 8080)
  LOG_LEVEL   'debug' enables request logging   (dev overlay sets debug)
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").strip().lower()
HTTP_PORT = int(os.environ.get("HTTP_PORT", os.environ.get("PORT", "8080")))
SERVICE = "orders-api"


def order_summary():
    """The single 'business' function - this is what the unit tests exercise."""
    return {"service": SERVICE, "orders": [], "count": 0, "logLevel": LOG_LEVEL}


class Handler(BaseHTTPRequestHandler):
    server_version = "orders-api/1.0"

    def _send_json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 - name mandated by http.server
        if self.path == "/healthz":
            self._send_json(200, {"status": "ok", "service": SERVICE})
        elif self.path == "/readyz":
            self._send_json(200, {"status": "ready", "service": SERVICE})
        elif self.path == "/orders":
            self._send_json(200, order_summary())
        else:
            self._send_json(404, {"error": "not found", "path": self.path})

    def log_message(self, fmt, *args):
        if LOG_LEVEL == "debug":
            super().log_message(fmt, *args)


def main():
    httpd = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
    print(f"{SERVICE} listening on 0.0.0.0:{HTTP_PORT} (log level: {LOG_LEVEL})", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
