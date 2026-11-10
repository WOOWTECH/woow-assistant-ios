import base64
import http.client
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

from pypdf import PdfWriter
from pypdf.generic import DictionaryObject, NameObject, DecodedStreamObject
import worker


def fixture(encrypted=False):
    writer = PdfWriter()
    for text in ["Alpha evidence", "", "Beta evidence"]:
        page = writer.add_blank_page(width=612, height=792)
        font = DictionaryObject({NameObject("/Type"): NameObject("/Font"), NameObject("/Subtype"): NameObject("/Type1"), NameObject("/BaseFont"): NameObject("/Helvetica")})
        page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"): DictionaryObject({NameObject("/F1"): writer._add_object(font)})})
        stream = DecodedStreamObject()
        stream.set_data(("BT /F1 18 Tf 40 700 Td (%s) Tj ET" % text).encode("ascii"))
        page[NameObject("/Contents")] = writer._add_object(stream)
    writer.add_metadata({"/Title": "Execution Fixture"})
    if encrypted:
        writer.encrypt("test-only", algorithm="RC4-128")
    result = io.BytesIO()
    writer.write(result)
    return result.getvalue()


def request(data=None, **options):
    data = fixture() if data is None else data
    result = {"version": 1, "requestID": "fixture-001", "operation": "extract_pdf", "revision": worker.REVISION,
              "scriptSHA256": worker.SCRIPT_HASH, "pdfBase64": base64.b64encode(data).decode(),
              "inputSHA256": worker.digest(data), "metadataOnly": False}
    result.update(options)
    return result


class WorkerTests(unittest.TestCase):
    def test_pinned_original_script_and_manifest(self):
        self.assertEqual(worker.digest(worker.source_bytes()), worker.SCRIPT_HASH)
        manifest = json.loads((worker.VENDOR / "manifest.json").read_text())
        self.assertEqual(manifest, [{"file": "scripts/extract_pdf.py", "runnable": True, "needs": ["apk:py3-pypdf"]}])

    def test_actual_original_script_text_and_page_selection(self):
        response = worker.handle(request(pages="3,1-2,3"))
        self.assertNotIn("error", response)
        self.assertEqual(response["pageCount"], 3)
        self.assertEqual([p["number"] for p in response["pages"]], [3, 1, 2, 3])
        self.assertEqual([p["text"] for p in response["pages"]], ["Beta evidence", "Alpha evidence", "", "Beta evidence"])
        self.assertEqual(response["emptyPages"], [2])
        self.assertEqual(response["scriptSHA256"], worker.SCRIPT_HASH)

    def test_metadata_uses_original_script(self):
        response = worker.handle(request(metadataOnly=True))
        self.assertEqual(response["metadata"]["title"], "Execution Fixture")
        self.assertEqual(response["metadata"]["pages"], "3")
        self.assertEqual(response["pages"], [])

    def test_original_empty_page_exit_three_remains_an_outcome(self):
        response = worker.handle(request(pages="2"))
        self.assertEqual(response["emptyPages"], [2])
        self.assertEqual(response["pages"], [{"number": 2, "text": ""}])

    def test_password_is_not_in_process_arguments_or_error_output(self):
        encrypted = fixture(encrypted=True)
        for password in (None, "wrong-test-password"):
            options = {} if password is None else {"password": password}
            response = worker.handle(request(encrypted, **options))
            self.assertEqual(response["error"], "passwordRequired")
            self.assertNotIn("wrong-test-password", json.dumps(response))
        response = worker.handle(request(encrypted, password="test-only", pages="1"))
        self.assertEqual(response["pages"][0]["text"], "Alpha evidence")
        with patch.object(worker.subprocess, "run", wraps=subprocess.run) as run:
            worker.handle(request(encrypted, password="test-only"))
            args, kwargs = run.call_args
            self.assertNotIn("test-only", str(args))
            self.assertEqual(set(kwargs["env"]), {"PATH", "LANG"})

    def test_invalid_bounds_and_no_arbitrary_paths_or_arguments(self):
        for pages in ("0", "4", "3-1", "1,,2", "-1", "1-", "1-201", "1;echo", "1-999999999999999"):
            with self.subTest(pages=pages):
                self.assertEqual(worker.handle(request(pages=pages))["error"], "invalidPages")
        for key in ("path", "args", "script", "out", "command", "endpoint"):
            with self.subTest(key=key):
                self.assertEqual(worker.handle(request(**{key: "untrusted"}))["error"], "invalidRequest")

    def test_bad_pdf_hash_source_and_schema_fail_closed(self):
        self.assertEqual(worker.handle(request(b"%PDF-bad"))["error"], "invalidPDF")
        self.assertEqual(worker.handle(request(inputSHA256="0" * 64))["error"], "invalidPDF")
        self.assertEqual(worker.handle(request(scriptSHA256="0" * 64))["error"], "invalidRequest")
        self.assertEqual(worker.handle(request(pdfBase64="../file"))["error"], "invalidRequest")
        self.assertEqual(worker.handle(request(version=True))["error"], "invalidRequest")
        self.assertEqual(worker.handle(["not an object"])["error"], "invalidRequest")
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder)
            (source / "extract_pdf.py").write_text("print('not the original')")
            (source / "manifest.json").write_bytes((worker.VENDOR / "manifest.json").read_bytes())
            with patch.object(worker, "VENDOR", source):
                self.assertEqual(worker.handle(request())["error"], "sourceMismatch")

    def test_file_and_output_limits(self):
        with patch.object(worker, "MAX_FILE", 10):
            self.assertEqual(worker.handle(request())["error"], "fileTooLarge")
        with patch.object(worker, "MAX_OUTPUT", 4):
            with self.assertRaisesRegex(worker.Rejected, "outputTooLarge"):
                worker.invoke(lambda _: print("12345"), [])

    def test_stdio_real_process_protocol(self):
        child = subprocess.run([os.sys.executable, "-I", str(Path(worker.__file__).resolve())],
                               input=json.dumps(request(pages="1")).encode(), capture_output=True, timeout=65)
        self.assertEqual(child.returncode, 0)
        self.assertEqual(child.stderr, b"")
        self.assertEqual(json.loads(child.stdout)["pages"][0]["text"], "Alpha evidence")


class ValidationHandler(worker.Handler):
    # Test-only authentication route. This is not an internet gateway.
    redirected_requests = 0
    authenticated_requests = 0

    def do_POST(self):
        if self.path == "/v1/unexpected-redirect-target":
            type(self).redirected_requests += 1
            self.send_error(403)
            return
        if self.path == "/v1/authenticated":
            if self.headers.get("Authorization") != "Bearer synthetic-pdf-worker-bearer":
                self.send_error(401)
                return
            type(self).authenticated_requests += 1
            self.path = "/v1/extract-pdf"
            return super().do_POST()
        if self.path == "/v1/extract-pdf":
            return super().do_POST()
        if self.path in ("/v1/invalid-hash", "/v1/invalid-pages"):
            value = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            response = worker.handle(value)
            if self.path.endswith("invalid-hash"):
                response["scriptSHA256"] = "0" * 64
            else:
                response["pages"] = list(reversed(response["pages"]))
            body = json.dumps(response).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/v1/redirect":
            self.send_response(307)
            self.send_header("Location", "/v1/unexpected-redirect-target")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/v1/oversized":
            self.send_response(200)
            self.send_header("Content-Length", str(worker.MAX_OUTPUT * 3 + 1))
            self.end_headers()
        else:
            super().do_POST()


class HTTPIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = worker.http.server.HTTPServer(("127.0.0.1", 0), ValidationHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join()
        cls.server.server_close()

    def post(self, payload, path="/v1/extract-pdf", extra=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=65)
        headers = {"Content-Type": "application/json"}
        headers.update(extra or {})
        connection.request("POST", path, json.dumps(payload), headers)
        response = connection.getresponse()
        status, body = response.status, response.read()
        connection.close()
        return status, body

    def test_actual_http_request_through_original_script(self):
        status, body = self.post(request(pages="1-3"))
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["pages"][0]["text"], "Alpha evidence")

    def test_reject_browser_origin_and_nonprotocol_path(self):
        self.assertEqual(self.post(request(), extra={"Origin": "https://untrusted.example"})[0], 403)
        self.assertEqual(self.post(request(), path="/shell")[0], 403)
        self.assertEqual(self.post(request(), extra={"Host": "untrusted.example"})[0], 403)

    def test_swift_client_to_real_worker(self):
        binary = os.environ.get("SKILL_EXECUTION_TEST_BINARY")
        if not binary:
            self.skipTest("set SKILL_EXECUTION_TEST_BINARY to the compiled standalone checker")
        repo = Path(__file__).resolve().parents[2]
        endpoint = "http://127.0.0.1:%d/v1/extract-pdf" % self.server.server_port
        ValidationHandler.redirected_requests = 0
        ValidationHandler.authenticated_requests = 0
        result = subprocess.run([binary, str(repo / "Sources/AssistantSkills/Resources/MikaBundledSkills.json"), endpoint, "--test-protocol-rejections"],
                                capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace")[-2000:])
        self.assertIn(b"PASS Swift HTTP -> pinned original Python script integration", result.stdout)
        self.assertIn(b"PASS real HTTP redirect, provenance, page and size rejection", result.stdout)
        self.assertEqual(ValidationHandler.authenticated_requests, 1)
        self.assertEqual(ValidationHandler.redirected_requests, 0, "Neither a PDF nor its bearer may follow a redirect")


if __name__ == "__main__":
    unittest.main()
