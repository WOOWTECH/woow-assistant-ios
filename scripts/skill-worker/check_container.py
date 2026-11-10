#!/usr/bin/env python3
"""Real Docker acceptance, not a deployment or a general execution endpoint.

Host needs Python's standard library and Docker; no pip install, secrets, host
mounts, published ports or image push. Build using the adjacent Dockerfile first.
All PDF fixtures and passwords are synthetic. Probe code is acceptance-only;
normal requests always use the image's unchanged worker entrypoint.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parent
BASE_DIGEST = "sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b"
AMD64_DIGEST = "sha256:05a994d2344eb364cc186910f4fc8786a38215f39f00d0acc25bff33a08f4177"
BASE = "python:3.12.16-slim-trixie@" + BASE_DIGEST
REVISION = "0c172724f3f0c96f7345262588072f6e95db1138"
SCRIPT_HASH = "41c2e2b51cd23173e0891084d0cd93d54e300e5fd571876740de36ac5968817c"
MANIFEST_HASH = "010bf7bf1102f06e20b29b8b63e0ceedf5b7e6856cb76f67ae8f9e2fa74515cf"
MEMORY = 768 * 1024 * 1024
TMP_SIZE = 64 * 1024 * 1024
TMP_OPTIONS = "rw,noexec,nosuid,nodev,size=64m,mode=1777"


class Failed(Exception):
    pass


def require(condition, label):
    if not condition:
        raise Failed(label)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def verify_sources():
    require(sha((ROOT / "vendor/extract_pdf.py").read_bytes()) == SCRIPT_HASH, "local original script hash")
    require(sha((ROOT / "vendor/manifest.json").read_bytes()) == MANIFEST_HASH, "local original manifest hash")
    require(re.findall(r"^FROM (.+)$", (ROOT / "Dockerfile").read_text(), re.M) == [BASE], "exact pinned base")


def verify_registry():
    # Anonymous public pull token stays in memory and is never logged.
    with urllib.request.urlopen("https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/python:pull", timeout=30) as response:
        token = json.load(response)["token"]

    def fetch(path, digest):
        request = urllib.request.Request("https://registry-1.docker.io/v2/library/python/" + path, headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json",
        })
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read(2 * 1024 * 1024)
        require("sha256:" + sha(data) == digest, "official registry content digest")
        return json.loads(data)

    index = fetch("manifests/" + BASE_DIGEST, BASE_DIGEST)
    manifests = [m["digest"] for m in index["manifests"] if m.get("platform") == {"architecture": "amd64", "os": "linux"}]
    require(manifests == [AMD64_DIGEST], "pinned linux amd64 manifest")
    manifest = fetch("manifests/" + AMD64_DIGEST, AMD64_DIGEST)
    config_hash = manifest["config"]["digest"]
    config = fetch("blobs/" + config_hash, config_hash)
    require("PYTHON_VERSION=3.12.16" in config["config"]["Env"], "official Python version")
    return {"registry": "registry-1.docker.io/library/python", "index": BASE_DIGEST, "linux_amd64": AMD64_DIGEST}


def docker(*args, data=None, timeout=85):
    result = subprocess.run(["docker", *args], input=data, capture_output=True, timeout=timeout, check=False)
    if result.returncode:
        # Retain a bounded acceptance-probe failure label, never a traceback,
        # command line, protocol payload or arbitrary daemon output.
        lines = result.stderr.decode(errors="replace").splitlines()
        detail = lines[-1] if args[0] == "start" and lines else ""
        if not re.fullmatch(r"RuntimeError: [A-Za-z0-9 /_-]{1,120}", detail):
            detail = ""
        raise Failed("docker %s exit %d%s" % (args[0], result.returncode, ": " + detail if detail else ""))
    return result


class Containers:
    def __init__(self, image):
        self.image = image
        self.count = 0
        self.worker_requests = 0

    def run(self, payload=b"", code=None):
        options = ["create", "--interactive", "--pull=never", "--platform=linux/amd64",
                   "--network=none", "--read-only", "--cap-drop=ALL",
                   "--security-opt=no-new-privileges:true", "--user=65534:65534",
                   "--memory=768m", "--memory-swap=768m", "--cpus=1", "--pids-limit=32",
                   "--cgroupns=private", "--ipc=private", "--tmpfs=/tmp:" + TMP_OPTIONS]
        if code is not None:
            options += ["--entrypoint=python"]
        options += [self.image]
        if code is not None:
            options += ["-I", "-c", code]
        ident = docker(*options).stdout.decode().strip()
        require(re.fullmatch(r"[a-f0-9]{64}", ident) is not None, "created container ID")
        try:
            info = json.loads(docker("inspect", ident).stdout)[0]
            host, config = info["HostConfig"], info["Config"]
            require(config["User"] == "65534:65534", "configured nonroot user")
            require(host["ReadonlyRootfs"] and not host["Privileged"], "readonly unprivileged root")
            require(host["NetworkMode"] == "none" and not host.get("PortBindings"), "no external network or published ports")
            require(host["Memory"] == MEMORY and host["MemorySwap"] == MEMORY, "configured memory and no swap")
            require(host["NanoCpus"] == 1_000_000_000 and host["PidsLimit"] == 32, "configured CPU and PID bounds")
            require(host["CapDrop"] == ["ALL"] and not host.get("CapAdd"), "drop all capabilities")
            require(host["SecurityOpt"] == ["no-new-privileges:true"], "no new privileges")
            require(not host.get("Binds") and not host.get("Mounts") and not host.get("VolumesFrom"), "no host or volume mounts")
            require(all(m["Type"] == "tmpfs" and m["Destination"] == "/tmp" for m in info.get("Mounts", [])), "only scratch tmpfs mount")
            require(not config.get("Volumes") and not host.get("Devices") and not host.get("DeviceRequests"), "no inherited volumes or devices")
            require(host["Tmpfs"] == {"/tmp": TMP_OPTIONS}, "bounded scratch mount")
            require(host["CgroupnsMode"] == "private" and host["IpcMode"] == "private" and host["PidMode"] == "", "private namespaces")
            if code is None:
                require(config["Entrypoint"] == ["python", "-I", "/opt/worker/worker.py"], "original worker entrypoint")
            result = docker("start", "--attach", "--interactive", ident, data=payload)
            state = json.loads(docker("inspect", ident).stdout)[0]["State"]
            require(state["Status"] == "exited" and state["ExitCode"] == 0 and not state["OOMKilled"], "container exited successfully")
            require(not result.stderr, "container stderr is empty")
            require(len(result.stdout) <= 1024 * 1024, "bounded synthetic response")
            self.count += 1
            if code is None:
                self.worker_requests += 1
            return json.loads(result.stdout)
        finally:
            docker("rm", "--force", ident, timeout=20)


# These probes execute inside the real container under exactly the same limits
# as PDF extraction. No host tools/packages or bind mounts are used as substitutes.
PROBE = r'''
import errno, hashlib, json, os, socket, sys
from pathlib import Path
import pypdf
def need(value, label):
    if not value: raise RuntimeError(label)
need(os.getuid() == os.geteuid() == 65534 and os.getgid() == os.getegid() == 65534, "effective nonroot identity")
status = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines() if ":" in line)
need(all(int(status[k].strip(), 16) == 0 for k in ("CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb")), "effective capabilities")
need(status["NoNewPrivs"].strip() == "1" and status["Seccomp"].strip() == "2", "effective privilege restrictions")
need(os.statvfs("/").f_flag & os.ST_RDONLY, "effective root readonly flag")
try:
    Path("/opt/worker/acceptance-write-probe").write_text("synthetic")
    raise RuntimeError("root write unexpectedly succeeded")
except OSError as error:
    need(error.errno in (errno.EROFS, errno.EACCES), "root write refusal")
scratch = Path("/tmp/container-acceptance.txt")
scratch.write_text("scratch works")
need(scratch.read_text() == "scratch works", "tmp read/write")
scratch.unlink()
mounts = [line.split() for line in Path("/proc/self/mountinfo").read_text().splitlines()]
tmp = [m for m in mounts if m[4] == "/tmp"]
need(len(tmp) == 1 and tmp[0][tmp[0].index("-")+1] == "tmpfs", "effective scratch filesystem")
need({"rw", "nosuid", "nodev", "noexec"} <= set(tmp[0][5].split(",")), "effective scratch options")
stats = os.statvfs("/tmp")
need(stats.f_blocks * stats.f_frsize == 64 * 1024 * 1024, "effective scratch size")
interfaces = sorted(p.name for p in Path("/sys/class/net").iterdir())
need(interfaces == ["lo"], "only loopback interface")
need(len(Path("/proc/net/route").read_text().splitlines()) == 1, "no IPv4 routes")
with socket.socket() as connection:
    connection.settimeout(1)
    result = connection.connect_ex(("203.0.113.1", 443))
need(result in (errno.ENETUNREACH, errno.EHOSTUNREACH), "external connect is unreachable")
need(not Path("/var/run/docker.sock").exists(), "no Docker socket")
# Ubuntu acceptance intentionally requires cgroup v2; unsupported limits fail.
cg = Path("/sys/fs/cgroup")
limits = {key: (cg/key).read_text().strip() for key in ("memory.max", "memory.swap.max", "pids.max", "cpu.max")}
need(limits["memory.max"] == str(768*1024*1024) and limits["memory.swap.max"] == "0", "effective memory bounds")
need(limits["pids.max"] == "32", "effective PID bound")
quota, period = map(int, limits["cpu.max"].split())
need(quota == period and period > 0, "effective one CPU bound")
hashes = {name: hashlib.sha256(Path("/opt/worker", name).read_bytes()).hexdigest() for name in ("worker.py", "requirements.txt", "vendor/extract_pdf.py", "vendor/manifest.json")}
print(json.dumps({"uid": os.geteuid(), "gid": os.getegid(), "capabilities": "0", "noNewPrivs": 1,
 "rootReadonly": True, "tmpBytes": stats.f_blocks * stats.f_frsize, "tmpReadWrite": True,
 "networkInterfaces": interfaces, "externalConnectErrno": result, "cgroups": limits,
 "hashes": hashes, "python": sys.version.split()[0], "pypdf": pypdf.__version__}))
'''

FIXTURES = r'''
import base64, io, json
from pypdf import PdfWriter
from pypdf.generic import DictionaryObject, NameObject, DecodedStreamObject
def fixture(encrypted):
    writer = PdfWriter()
    for text in ("Alpha evidence", "", "Beta evidence"):
        page = writer.add_blank_page(width=612, height=792)
        font = DictionaryObject({NameObject("/Type"): NameObject("/Font"), NameObject("/Subtype"): NameObject("/Type1"), NameObject("/BaseFont"): NameObject("/Helvetica")})
        page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"): DictionaryObject({NameObject("/F1"): writer._add_object(font)})})
        stream = DecodedStreamObject()
        stream.set_data(("BT /F1 18 Tf 40 700 Td (%s) Tj ET" % text).encode("ascii"))
        page[NameObject("/Contents")] = writer._add_object(stream)
    writer.add_metadata({"/Title": "Execution Fixture", "/Author": "Container Acceptance"})
    if encrypted: writer.encrypt("synthetic-container-password", algorithm="RC4-128")
    data = io.BytesIO(); writer.write(data)
    return base64.b64encode(data.getvalue()).decode("ascii")
print(json.dumps({"plain": fixture(False), "encrypted": fixture(True)}))
'''

TAMPER = r'''
import json, shutil, subprocess, sys, tempfile
from pathlib import Path
# A separate scratch copy exercises the unchanged worker's real hash refusal.
# The image's original source remains read-only and is checked again afterward.
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    shutil.copyfile("/opt/worker/worker.py", root/"worker.py")
    (root/"vendor").mkdir()
    shutil.copyfile("/opt/worker/vendor/manifest.json", root/"vendor/manifest.json")
    (root/"vendor/extract_pdf.py").write_text("raise RuntimeError('must never execute')\n")
    result = subprocess.run([sys.executable, "-I", str(root/"worker.py")], input=sys.stdin.buffer.read(), capture_output=True, timeout=65)
    if result.returncode or result.stderr: raise RuntimeError("tamper worker failed")
    print(result.stdout.decode())
'''


def acceptance(image, report):
    containers = Containers(image)
    probe = containers.run(code=PROBE)
    require(probe["python"] == "3.12.16" and probe["pypdf"] == "6.21.4", "actual pinned Python and dependency")
    expected_hashes = {name: sha((ROOT/name).read_bytes()) for name in probe["hashes"]}
    require(probe["hashes"] == expected_hashes, "image contains exact local worker and pinned source")
    report["isolation"] = probe
    # Docker also creates its own /etc/hosts, hostname and resolv.conf mounts;
    # no user host bind, workspace, volume, socket or credentials are supplied.
    report["mountPolicy"] = "No user host/volume mounts; Docker-managed hosts/hostname/resolv.conf only, plus private tmpfs."
    fixtures = containers.run(code=FIXTURES)
    plain = base64.b64decode(fixtures["plain"], validate=True)
    encrypted = base64.b64decode(fixtures["encrypted"], validate=True)
    require(plain.startswith(b"%PDF-") and encrypted.startswith(b"%PDF-"), "actual generated PDF fixtures")

    def request(data=plain, **options):
        body = {"version": 1, "requestID": "container-synthetic", "operation": "extract_pdf", "revision": REVISION,
                "scriptSHA256": SCRIPT_HASH, "pdfBase64": base64.b64encode(data).decode(), "inputSHA256": sha(data), "metadataOnly": False}
        body.update(options)
        return body

    def call(body, error=None, code=None):
        response = containers.run(json.dumps(body).encode(), code=code)
        for key in ("version", "requestID", "revision", "inputSHA256"):
            require(response[key] == body[key], "response binding " + key)
        require(response["scriptSHA256"] == SCRIPT_HASH, "response original source hash")
        require(response.get("error") == error, "expected worker outcome " + str(error))
        if error:
            require(set(response) == {"version", "requestID", "revision", "scriptSHA256", "inputSHA256", "error"}, "refusal exposes no document or request fields")
        return response

    checks = report["checks"]
    response = call(request())
    pages = [{"number": 1, "text": "Alpha evidence"}, {"number": 2, "text": ""}, {"number": 3, "text": "Beta evidence"}]
    require(response["pageCount"] == 3 and response["pages"] == pages and response["emptyPages"] == [2], "exact complete PDF extraction")
    metadata = {"producer": "pypdf", "title": "Execution Fixture", "author": "Container Acceptance", "pages": "3"}
    require(response["metadata"] == metadata, "exact metadata")
    checks.append("original script: exact text, three pages, empty page and metadata")
    response = call(request(pages="3,1-2,3"))
    require(response["pages"] == [pages[2], pages[0], pages[1], pages[2]] and response["emptyPages"] == [2], "exact selected page order and duplicates")
    checks.append("selected pages retain order and duplicates")
    response = call(request(metadataOnly=True))
    require(response["pageCount"] == 3 and response["pages"] == [] and response["emptyPages"] == [] and response["metadata"] == metadata, "metadata only")
    checks.append("metadata only uses original script")
    response = call(request(pages="2"))
    require(response["pages"] == [pages[1]] and response["emptyPages"] == [2], "original empty-text exit is preserved")
    checks.append("empty selected page remains a valid empty outcome")
    for password in (None, "synthetic-wrong-password"):
        options = {} if password is None else {"password": password}
        call(request(encrypted, **options), error="passwordRequired")
    checks.append("encrypted PDF rejects missing and wrong passwords")
    response = call(request(encrypted, password="synthetic-container-password"))
    require(response["pages"] == pages and response["metadata"] == metadata, "actual encrypted PDF decrypted with correct password")
    checks.append("encrypted PDF with correct password extracts exact text")
    call(request(b"%PDF-malformed"), error="invalidPDF")
    checks.append("malformed PDF refused")
    call(request(path="/etc/passwd"), error="invalidRequest")
    checks.append("unknown path cannot grant filesystem access")
    call(request(scriptSHA256="0"*64), error="invalidRequest")
    call(request(inputSHA256="0"*64), error="invalidPDF")
    call(request(pages="4"), error="invalidPages")
    checks.append("source identity, input hash and page bounds refused")
    call(request(), error="sourceMismatch", code=TAMPER)
    require(containers.run(code=PROBE)["hashes"] == expected_hashes, "original image source unchanged after tamper test")
    checks.append("actual tampered scratch script refused before execution; original image unchanged")
    report["containersPassed"] = containers.count
    report["originalEntrypointRequestsPassed"] = containers.worker_requests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default="woow-skill-worker:acceptance")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--verify-base-only", action="store_true")
    args = parser.parse_args()
    report = {"status": "failed", "checks": [], "deployment": False, "syntheticFixturesOnly": True}
    try:
        verify_sources()
        report["base"] = verify_registry()
        if args.verify_base_only:
            report["status"] = "registry-and-source-verified; containers-not-run"
        else:
            acceptance(args.image, report)
            report["status"] = "passed"
    except Exception as error:
        # Never print subprocess arguments, request bodies, passwords or tokens.
        report["failure"] = str(error) if isinstance(error, Failed) else type(error).__name__
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 1 if report["status"] == "failed" else 0


if __name__ == "__main__":
    sys.exit(main())
