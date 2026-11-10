#!/usr/bin/env python3
"""Bounded, pinned extract_pdf worker. Host mode is NOT an OS security sandbox.

One JSON request on stdin / one JSON response on stdout, or loopback-only HTTP
for integration tests. Production isolation requires the documented container
runner and an independently approved TLS/auth gateway; none is deployed here.
"""
import argparse
import base64
import contextlib
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import re
import resource
import runpy
import subprocess
import sys
import tempfile

REVISION = "0c172724f3f0c96f7345262588072f6e95db1138"
SCRIPT_HASH = "41c2e2b51cd23173e0891084d0cd93d54e300e5fd571876740de36ac5968817c"
MANIFEST_HASH = "010bf7bf1102f06e20b29b8b63e0ceedf5b7e6856cb76f67ae8f9e2fa74515cf"
MAX_FILE = 10 * 1024 * 1024
MAX_REQUEST = 14 * 1024 * 1024
MAX_OUTPUT = 2 * 1024 * 1024
MAX_PAGES = 200
VENDOR = Path(__file__).resolve().parent / "vendor"


class Rejected(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source_bytes():
    script = (VENDOR / "extract_pdf.py").read_bytes()
    manifest = (VENDOR / "manifest.json").read_bytes()
    if digest(script) != SCRIPT_HASH or digest(manifest) != MANIFEST_HASH:
        raise Rejected("sourceMismatch")
    return script


def page_numbers(spec, count):
    if spec is None:
        if count > MAX_PAGES:
            raise Rejected("invalidPages")
        return list(range(1, count + 1))
    if not isinstance(spec, str) or len(spec) > 1024:
        raise Rejected("invalidPages")
    result = []
    for part in spec.split(","):
        match = re.fullmatch(r"([0-9]+)(?:-([0-9]+))?", part.strip())
        if not match:
            raise Rejected("invalidPages")
        first, last = int(match[1]), int(match[2] or match[1])
        if first < 1 or last < first or last > count or len(result) + last - first + 1 > MAX_PAGES:
            raise Rejected("invalidPages")
        result.extend(range(first, last + 1))
    return result


def validate(request):
    allowed = {"version", "requestID", "operation", "revision", "scriptSHA256", "pdfBase64", "inputSHA256", "metadataOnly", "pages", "password"}
    if not isinstance(request, dict) or set(request) - allowed:
        raise Rejected("invalidRequest")
    if (type(request.get("version")) is not int or request["version"] != 1
            or request.get("operation") != "extract_pdf" or request.get("revision") != REVISION
            or request.get("scriptSHA256") != SCRIPT_HASH
            or not isinstance(request.get("requestID"), str)
            or not re.fullmatch(r"[A-Za-z0-9-]{1,64}", request["requestID"])
            or type(request.get("metadataOnly")) is not bool):
        raise Rejected("invalidRequest")
    password = request.get("password")
    if password is not None and (not isinstance(password, str) or len(password.encode("utf-8")) > 1024):
        raise Rejected("invalidRequest")
    if request.get("pages") is not None:
        page_numbers(request["pages"], 2**63 - 1)
    try:
        data = base64.b64decode(request["pdfBase64"], validate=True)
    except (ValueError, KeyError, TypeError):
        raise Rejected("invalidRequest")
    if len(data) > MAX_FILE:
        raise Rejected("fileTooLarge")
    if not data.startswith(b"%PDF-") or request.get("inputSHA256") != digest(data):
        raise Rejected("invalidPDF")
    return data


def envelope(request):
    # Echo only bounded protocol IDs/hashes, never filenames, PDF text or secrets.
    request = request if isinstance(request, dict) else {}
    ident = request.get("requestID", "")
    sha = request.get("inputSHA256", "")
    return {"version": 1, "requestID": ident if isinstance(ident, str) and re.fullmatch(r"[A-Za-z0-9-]{1,64}", ident) else "",
            "revision": REVISION, "scriptSHA256": SCRIPT_HASH,
            "inputSHA256": sha if isinstance(sha, str) and re.fullmatch(r"[a-f0-9]{64}", sha) else ""}


def invoke(main, args):
    output, errors = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            main(args)
    except SystemExit as error:
        if error.code != 3:  # 3 is the original script's scanned/empty-text outcome.
            reason = "passwordRequired" if "encrypted; pass the right" in errors.getvalue() else "invalidPDF"
            raise Rejected(reason)
    text = output.getvalue()
    if len(text.encode("utf-8")) > MAX_OUTPUT:
        raise Rejected("outputTooLarge")
    return text


def extract_in_child(request):
    data = validate(request)
    # Parent creates a private temporary cwd; no input can supply paths/argv/code.
    Path("input.pdf").write_bytes(data)
    module = runpy.run_path(str(Path("extract_pdf.py").resolve()), run_name="pinned_mika_worker")
    args = ["input.pdf"]
    if request.get("password") is not None:
        args += ["--password", request["password"]]  # In-process argv; never process-list arguments.
    info = json.loads(invoke(module["main"], args + ["--metadata"]))
    count = info["pages"]
    if type(count) is not int or not 1 <= count <= 100_000:
        raise Rejected("invalidPDF")
    metadata = {key: str(value) for key, value in info.items()}
    pages = []
    size = sum(len((key + value).encode("utf-8")) for key, value in metadata.items())
    if not request["metadataOnly"]:
        for number in page_numbers(request.get("pages"), count):
            # Each page passes through the unmodified original script. Separate
            # calls avoid confusing document text that itself contains page markers.
            body = invoke(module["main"], args + ["--pages", str(number)])
            marker = "--- page %d ---\n" % number
            if not body.startswith(marker) or not body.endswith("\n"):
                raise Rejected("invalidPDF")
            text = body[len(marker):-1]
            size += len(text.encode("utf-8")) + 32
            if size > MAX_OUTPUT:
                raise Rejected("outputTooLarge")
            pages.append({"number": number, "text": text})
    if size > MAX_OUTPUT:
        raise Rejected("outputTooLarge")
    return {"pageCount": count, "pages": pages, "metadata": metadata,
            "emptyPages": [page["number"] for page in pages if not page["text"]]}


def child_main():
    # Resource limits complement (and do not replace) container isolation.
    resource.setrlimit(resource.RLIMIT_CPU, (30, 30))
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_FILE + 1, MAX_FILE + 1))
    if sys.platform == "linux":
        resource.setrlimit(resource.RLIMIT_AS, (512 * 1024 * 1024, 512 * 1024 * 1024))
    request = json.load(sys.stdin)
    response = envelope(request)
    try:
        response.update(extract_in_child(request))
    except Rejected as error:
        response["error"] = str(error)
    except BaseException:
        response["error"] = "workerFailed"
    sys.stdout.write(json.dumps(response, ensure_ascii=False))


def handle(request):
    response = envelope(request)
    try:
        validate(request)
        source = source_bytes()
        with tempfile.TemporaryDirectory(prefix="woow-pdf-") as folder:
            os.chmod(folder, 0o700)
            Path(folder, "extract_pdf.py").write_bytes(source)
            # stdout is a bounded file, stderr discarded; no PDF/password logging.
            with tempfile.TemporaryFile() as output:
                child = subprocess.run([sys.executable, "-I", str(Path(__file__).resolve()), "--child"],
                    input=json.dumps(request).encode("utf-8"), stdout=output, stderr=subprocess.DEVNULL,
                    cwd=folder, env={"PATH": os.defpath, "LANG": "C.UTF-8"}, timeout=60, check=False)
                output.seek(0)
                body = output.read(MAX_OUTPUT * 3 + 1)
            if child.returncode != 0 or len(body) > MAX_OUTPUT * 3:
                raise Rejected("workerFailed")
            return json.loads(body)
    except Rejected as error:
        response["error"] = str(error)
    except (Exception,):
        response["error"] = "workerFailed"
    return response


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.connection.settimeout(10)
        # Loopback server is a test harness, not a remotely exposed API. Reject
        # browser-origin requests and DNS-rebinding Host names.
        if self.path != "/v1/extract-pdf" or self.headers.get("Origin") or self.headers.get("Host", "").split(":")[0] not in ("127.0.0.1", "localhost"):
            self.send_error(403)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_REQUEST or self.headers.get("Content-Type") != "application/json":
                raise ValueError()
            request = json.loads(self.rfile.read(length))
        except (ValueError, OSError):
            self.send_error(400)
            return
        body = json.dumps(handle(request), ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--child", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--listen-loopback", type=int, metavar="PORT")
    args = parser.parse_args()
    if args.child:
        child_main()
    elif args.listen_loopback is not None:
        source_bytes()
        server = http.server.HTTPServer(("127.0.0.1", args.listen_loopback), Handler)
        print("Loopback worker port %d" % server.server_port, file=sys.stderr, flush=True)
        server.serve_forever()
    else:
        raw = sys.stdin.buffer.read(MAX_REQUEST + 1)
        try:
            if len(raw) > MAX_REQUEST:
                raise ValueError()
            response = handle(json.loads(raw))
        except ValueError:
            response = {**envelope({}), "error": "invalidRequest"}
        print(json.dumps(response, ensure_ascii=False))


if __name__ == "__main__":
    main()
