import contextlib
import io
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

import backend_api_test


class BackendTests(unittest.TestCase):
    def exercise(self, bad_read=False, bad_delete=False):
        state = {"food": None, "deleted": False}

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def respond(self, status, data):
                body = json.dumps(data, ensure_ascii=False).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def read(self):
                return json.loads(self.rfile.read(int(self.headers["Content-Length"])))

            def do_POST(self):
                state["food"] = self.read()
                state["food"]["worth_it"] = "yes"
                self.respond(200, {"id": 1})

            def do_GET(self):
                if urlsplit(self.path).path == "/api/tracks/days":
                    self.respond(200, {"days": []})
                elif bad_read:
                    self.respond(200, "malformed record")
                else:
                    self.respond(200, state["food"])

            def do_PATCH(self):
                body = self.read()
                fields = body.get("fields", body)
                if fields.get("preference") == 60:
                    self.respond(400, {"error": "invalid preference"})
                    return
                if "worth_it" in fields:
                    fields["worth_it"] = "yes" if fields["worth_it"] else "no"
                state["food"].update(fields)
                self.respond(200, {"ok": True})

            def do_DELETE(self):
                state["deleted"] = True
                self.respond(500 if bad_delete else 200, {"ok": not bad_delete})

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                result = backend_api_test.run(f"http://127.0.0.1:{server.server_port}", "none")
            return result, state
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_success(self):
        result, state = self.exercise()
        self.assertEqual(result, 0)
        self.assertTrue(state["deleted"])

    def test_exception_still_cleans_up(self):
        result, state = self.exercise(bad_read=True)
        self.assertEqual(result, 1)
        self.assertTrue(state["deleted"])

    def test_cleanup_failure_fails_test(self):
        result, state = self.exercise(bad_delete=True)
        self.assertEqual(result, 1)
        self.assertTrue(state["deleted"])
