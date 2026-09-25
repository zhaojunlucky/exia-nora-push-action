"""Exercise the real crane client against nora's Basic-challenge/Bearer contract."""
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import tarfile
import subprocess
import tempfile
import threading
import unittest
import uuid
from urllib.parse import parse_qs, urlsplit



def digest(body):
    return "sha256:" + hashlib.sha256(body).hexdigest()


def archive(path):
    layer = io.BytesIO()
    with tarfile.open(fileobj=layer, mode="w") as tar:
        item = tarfile.TarInfo("hello.txt")
        item.size = 5
        tar.addfile(item, io.BytesIO(b"hello"))
    config = json.dumps({"architecture": "amd64", "os": "linux", "config": {},
                         "rootfs": {"type": "layers", "diff_ids": [digest(layer.getvalue())]}}).encode()
    files = {"config.json": config, "layer.tar": layer.getvalue(), "manifest.json": json.dumps([
        {"Config": "config.json", "RepoTags": ["fixture:latest"], "Layers": ["layer.tar"]}
    ]).encode()}
    with tarfile.open(path, "w") as tar:
        for name, body in files.items():
            item = tarfile.TarInfo(name)
            item.size = len(body)
            tar.addfile(item, io.BytesIO(body))


class Registry(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def body(self):
        if self.headers.get("Transfer-Encoding") == "chunked":
            body = bytearray()
            while True:
                size = int(self.rfile.readline().split(b";")[0], 16)
                if size == 0:
                    self.rfile.readline()
                    return bytes(body)
                body.extend(self.rfile.read(size))
                self.rfile.read(2)
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def reply(self, status, **headers):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        for name, value in headers.items():
            self.send_header(name.replace("_", "-"), value)
        self.end_headers()

    def handle_request(self):
        user_agent = self.headers.get("User-Agent", "")
        self.server.user_agents.append(user_agent)
        # Reproduce the public edge rejecting urllib before nora sees the request.
        if user_agent.startswith("Python-urllib/"):
            self.reply(403, Server="cloudflare", CF_Ray="fixture-ray")
            return
        auth = self.headers.get("Authorization")
        self.server.requests.append((self.command, self.path, auth))
        if self.server.preflight_status:
            self.reply(self.server.preflight_status, Retry_After="60")
            return
        if auth != "Bearer fixture-token":
            self.reply(401, WWW_Authenticate='Basic realm="nora"')
            return
        path = urlsplit(self.path).path
        if path == "/v2/":
            self.reply(200)
        elif self.command == "HEAD":
            found = path.rsplit("/", 1)[-1] in self.server.blobs
            self.reply(200 if found else 404)
        elif self.command == "POST" and path.endswith("/blobs/uploads/"):
            upload = "/v2/test/blobs/uploads/" + str(uuid.uuid4())
            self.server.uploads[upload] = b""
            self.reply(202, Location=upload)
        elif self.command == "PATCH":
            self.server.uploads[path] += self.body()
            self.reply(202, Location=path)
        elif self.command == "PUT" and "/blobs/uploads/" in path:
            body = self.server.uploads[path] + self.body()
            expected = parse_qs(urlsplit(self.path).query)["digest"][0]
            if digest(body) != expected:
                self.reply(400)
                return
            self.server.blobs[expected] = body
            self.reply(201, Docker_Content_Digest=expected, Location="/v2/test/blobs/" + expected)
        elif self.command == "PUT" and "/manifests/" in path:
            body = self.body()
            self.server.manifests[path.rsplit("/", 1)[-1]] = json.loads(body)
            self.reply(201, Docker_Content_Digest=digest(body))
        else:
            self.reply(404)

    do_GET = do_HEAD = do_POST = do_PATCH = do_PUT = handle_request


class PushImageTest(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Registry)
        self.server.requests = []
        self.server.user_agents = []
        self.server.blobs = {}
        self.server.uploads = {}
        self.server.manifests = {}
        self.server.preflight_status = None
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.archive = str(Path(self.directory.name) / "image.tar")
        archive(self.archive)
        self.image = f"127.0.0.1:{self.server.server_port}/test:pr-42-123-1"
        self.alias = f"127.0.0.1:{self.server.server_port}/test:pr-42"

    def push(self, token="fixture-token"):
        env = dict(os.environ, NORA_TOKEN=token, TMPDIR=self.directory.name)
        result = subprocess.run(
            ["bash", str(Path(__file__).with_name("push-image.sh")), self.archive, self.image, self.alias],
            env=env, capture_output=True, text=True, timeout=30,
        )
        # Temporary credentials must be removed after both success and failure.
        self.assertEqual(list(Path(self.directory.name).iterdir()), [Path(self.archive)])
        self.assertNotIn("fixture-token", result.stdout + result.stderr)
        return result

    def test_bearer_push_despite_basic_challenge(self):
        result = self.push()
        self.assertEqual(result.returncode, 0, result.stderr)
        requests = self.server.requests
        self.assertEqual(self.server.user_agents[0], "exia-nora-push-action/1.0")
        self.assertEqual(requests[0], ("GET", "/v2/", "Bearer fixture-token"))
        self.assertIn(("GET", "/v2/", None), requests)  # Crane sees the Basic challenge.
        self.assertTrue(all(auth == "Bearer fixture-token" for _, path, auth in requests if path != "/v2/"))
        self.assertEqual(set(self.server.manifests), {"pr-42-123-1", "pr-42"})
        for manifest in self.server.manifests.values():
            self.assertIn(manifest["config"]["digest"], self.server.blobs)
            for layer in manifest["layers"]:
                self.assertIn(layer["digest"], self.server.blobs)

    def test_preflight_failure_stops_before_upload(self):
        for status in (401, 403, 429):
            with self.subTest(status=status):
                self.server.preflight_status = status
                self.server.requests.clear()
                result = self.push()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"HTTP {status}", result.stderr)
                self.assertEqual(len(self.server.requests), 1)
                self.assertEqual(self.server.manifests, {})

    def test_missing_token_stops_before_network(self):
        result = self.push(token="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NORA_TOKEN", result.stderr)
        self.assertEqual(self.server.requests, [])



if __name__ == "__main__":
    unittest.main()
