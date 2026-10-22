"""Local-only web preview with same-origin API proxy. Production uses Caddy."""
import argparse
import functools
import http.server
import pathlib
import socket
import urllib.error
import urllib.request


class PreviewServer(http.server.ThreadingHTTPServer):
    # Windows SO_REUSEADDR can let an older preview keep accepting requests
    # alongside a new listener. Fail visibly if this port is already owned.
    allow_reuse_address = False

    def server_bind(self):
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


class Handler(http.server.SimpleHTTPRequestHandler):
    api = ""

    def _proxy(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            max_body = 10 * 1024 * 1024 if self.path.startswith("/api/v1/attachments/") else 2_097_152
            if length < 0 or length > max_body:
                self.send_error(413)
                return
            body = self.rfile.read(length) if length else None
            headers = {
                name: value
                for name, value in self.headers.items()
                if name.lower() in {"content-type", "authorization", "accept", "origin"}
            }
            request = urllib.request.Request(
                self.api + self.path, data=body, headers=headers, method=self.command
            )
            try:
                response = urllib.request.urlopen(request, timeout=25)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                data = response.read()
                self.send_response(response.status)
                self.send_header("Content-Type", response.headers.get("Content-Type", "application/json"))
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                if response.headers.get("Content-Disposition"):
                    self.send_header("Content-Disposition", response.headers["Content-Disposition"])
                self.end_headers()
                self.wfile.write(data)
        except (OSError, ValueError, urllib.error.URLError):
            self.send_error(502, "Dayflow API is not running")

    def do_GET(self):
        if self.path.startswith("/api/"):
            self._proxy()
        else:
            super().do_GET()

    def do_POST(self):
        if self.path.startswith("/api/"):
            self._proxy()
        else:
            self.send_error(405)

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--api", default="http://127.0.0.1:8000")
    parser.add_argument("--directory", default=str(pathlib.Path(__file__).resolve().parents[1] / "client" / "build" / "web"))
    args = parser.parse_args()
    Handler.api = args.api.rstrip("/")
    server = PreviewServer(
        ("127.0.0.1", args.port), functools.partial(Handler, directory=args.directory)
    )
    print(f"Dayflow preview: http://127.0.0.1:{args.port}", flush=True)
    server.serve_forever()
