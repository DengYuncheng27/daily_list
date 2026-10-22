"""Local proxy regression tests; use only ephemeral loopback ports and threads.

Run: python -m unittest discover -s scripts -p test_preview.py -v
No existing preview/API process or persistent application data is touched.
"""

from contextlib import contextmanager, ExitStack
import hashlib
import http.client
import http.server
import json
from pathlib import Path
import socket
import threading
import unittest
from unittest.mock import patch
import urllib.request

from preview import Handler, PreviewServer


MIB = 1024 * 1024


@contextmanager
def running(server):
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        if thread.is_alive():
            raise AssertionError("Temporary HTTP server thread did not stop.")


class PreviewTests(unittest.TestCase):
    def setUp(self):
        self.resources = ExitStack()
        self.addCleanup(self.resources.close)
        self.requests = []
        requests = self.requests
        self.download = b"\x00\xffprivate attachment bytes\n"
        download = self.download
        self.disposition = "attachment; filename*=UTF-8''%E6%8A%A5%E5%91%8A.pdf"
        disposition = self.disposition

        class StubAPI(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                requests.append({
                    "path": self.path, "size": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "authorization": self.headers.get("Authorization"),
                    "contentType": self.headers.get("Content-Type"),
                })
                response = json.dumps({"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}).encode()
                self.send_response(201)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

            def do_GET(self):
                requests.append({"path": self.path})
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(download)))
                self.send_header("Content-Disposition", disposition)
                self.end_headers()
                self.wfile.write(download)

        upstream = self.resources.enter_context(running(
            http.server.ThreadingHTTPServer(("127.0.0.1", 0), StubAPI),
        ))

        class TestHandler(Handler):
            api = f"http://127.0.0.1:{upstream.server_port}"

            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=str(Path(__file__).parent), **kwargs)

            def log_message(self, *args):
                pass

        # Preserve real HTTP forwarding while excluding machine-wide proxy
        # environment settings from these strictly loopback-only tests.
        direct = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.resources.enter_context(patch("preview.urllib.request.urlopen", direct.open))
        self.proxy = self.resources.enter_context(running(
            PreviewServer(("127.0.0.1", 0), TestHandler),
        ))

    @contextmanager
    def connection(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.proxy.server_port, timeout=5)
        try:
            yield connection
        finally:
            connection.close()

    def test_second_preview_cannot_bind_the_owned_port(self):
        with self.assertRaises(OSError):
            PreviewServer(self.proxy.server_address, Handler)
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.assertEqual(
                self.proxy.socket.getsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE), 1,
            )

    def test_reuse_address_socket_cannot_take_the_owned_port(self):
        # Specifically protects Windows against a permissive older listener;
        # portable hosts must reject a second bind to the same live endpoint too.
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as second:
            second.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            with self.assertRaises(OSError):
                second.bind(self.proxy.server_address)

    def test_large_attachment_and_exact_10_mib_limit_are_forwarded(self):
        for size in (2 * MIB + 123, 10 * MIB):
            with self.subTest(size=size), self.connection() as connection:
                body = b"a" * size
                path = "/api/v1/attachments/00000000-0000-0000-0000-000000000001?name=large.txt"
                connection.request("POST", path, body=body, headers={
                    "Content-Type": "application/octet-stream",
                    "Authorization": "Bearer synthetic-test-token",
                })
                response = connection.getresponse()
                self.assertEqual(response.status, 201)
                self.assertEqual(json.loads(response.read()), {
                    "size": size, "sha256": hashlib.sha256(body).hexdigest(),
                })
                self.assertEqual(self.requests[-1], {
                    "path": path, "size": size, "sha256": hashlib.sha256(body).hexdigest(),
                    "authorization": "Bearer synthetic-test-token",
                    "contentType": "application/octet-stream",
                })

    def assert_rejected_before_reading_body(self, path, content_length):
        with self.connection() as connection:
            # Declaring an oversized body must produce 413 immediately; sending
            # bytes first races an intentional early TCP close on Windows.
            connection.putrequest("POST", path)
            connection.putheader("Content-Length", str(content_length))
            connection.endheaders()
            response = connection.getresponse()
            self.assertEqual(response.status, 413)
            response.read()
        self.assertEqual(self.requests, [])

    def test_attachment_over_10_mib_is_413_without_contacting_upstream(self):
        self.assert_rejected_before_reading_body("/api/v1/attachments/file?name=large.txt", 10 * MIB + 1)

    def test_json_over_2_mib_is_413_without_contacting_upstream(self):
        self.assert_rejected_before_reading_body("/api/v1/sync", 2 * MIB + 1)

    def test_json_exact_2_mib_remains_allowed(self):
        prefix, suffix = b'{"padding":"', b'"}'
        body = prefix + b"x" * (2 * MIB - len(prefix) - len(suffix)) + suffix
        with self.connection() as connection:
            connection.request("POST", "/api/v1/sync", body=body, headers={"Content-Type": "application/json"})
            response = connection.getresponse()
            self.assertEqual(response.status, 201)
            self.assertEqual(json.loads(response.read())["size"], 2 * MIB)

    def test_download_preserves_binary_bytes_and_content_disposition(self):
        with self.connection() as connection:
            connection.request("GET", "/api/v1/attachments/file", headers={
                "Authorization": "Bearer synthetic-test-token",
            })
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.getheader("Content-Disposition"), self.disposition)
            self.assertEqual(response.getheader("Content-Type"), "application/octet-stream")
            self.assertEqual(response.getheader("Content-Length"), str(len(self.download)))
            self.assertEqual(response.getheader("Cache-Control"), "no-store")
            self.assertEqual(response.getheader("X-Content-Type-Options"), "nosniff")
            self.assertEqual(response.read(), self.download)


if __name__ == "__main__":
    unittest.main()
