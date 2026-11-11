#!/usr/bin/env python3
"""Encrypt a verified Ad Hoc IPA before retaining it as a public-repo artifact."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from release_ios import BUNDLE_ID, ReleaseError
from release_testflight import verified_export


OPENSSL = Path("/usr/bin/openssl")
PASSPHRASE_NAME = "IOS_DEVICE_ARTIFACT_PASSPHRASE"
ITERATIONS = 200000


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _crypt(args, passphrase):
    try:
        subprocess.run(
            [str(OPENSSL), "enc", "-aes-256-cbc", "-salt", "-pbkdf2",
             "-iter", str(ITERATIONS), "-md", "sha256", *args,
             "-pass", f"env:{PASSPHRASE_NAME}"],
            env={PASSPHRASE_NAME: passphrase},
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            check=True, timeout=120,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        raise ReleaseError("測試 IPA 加密或驗證失敗；未保留部分交付檔。") from None


def package(release, output, env=None):
    env = os.environ if env is None else env
    passphrase = env.get(PASSPHRASE_NAME, "")
    if not re.fullmatch(r"[!-~]{32,256}", passphrase):
        raise ReleaseError("需要 32 至 256 字元的隨機 ASCII 測試包密碼 secret。")
    if not OPENSSL.is_file():
        raise ReleaseError("找不到系統 OpenSSL，尚未產生測試包。")
    release = Path(release).resolve()
    output = Path(output).resolve()
    if output == release or release in output.parents or output.exists():
        raise ReleaseError("測試包輸出目錄必須為新的獨立路徑。")

    ipa, ipa_hash = verified_export(release, method="release-testing")
    report = json.loads((release / "report.json").read_text())
    if (report.get("bundle_id") != BUNDLE_ID or report.get("minimum_os") != "17.0"
            or report.get("platform") != "iphoneos" or not re.fullmatch(
                r"[1-9][0-9]{0,17}", str(report.get("build_number", "")))):
        raise ReleaseError("簽章報告缺少正確的裝置識別或建置編號。")

    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    encrypted = output / "WoowAssistant.ipa.enc"
    try:
        _crypt(["-e", "-in", str(ipa), "-out", str(encrypted)], passphrase)
        if not encrypted.is_file() or encrypted.stat().st_size <= 16:
            raise ReleaseError("加密測試包未完整產生。")
        with tempfile.TemporaryDirectory(prefix="woow-ipa-check-") as folder:
            decrypted = Path(folder) / "verified.ipa"
            _crypt(["-d", "-in", str(encrypted), "-out", str(decrypted)], passphrase)
            if digest(decrypted) != ipa_hash:
                raise ReleaseError("加密測試包的解密驗證與簽章報告不符。")
        manifest = {
            "schema": "woow-encrypted-ad-hoc-ipa-v1",
            "bundle_id": BUNDLE_ID,
            "build_number": report["build_number"],
            "minimum_os": "17.0",
            "cipher": "openssl-aes-256-cbc-pbkdf2-sha256",
            "iterations": ITERATIONS,
            "encrypted_sha256": digest(encrypted),
            "ipa_sha256": ipa_hash,
            "signed_export_verified": True,
            "physical_device_tested": False,
        }
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        os.chmod(encrypted, 0o600)
        os.chmod(output / "manifest.json", 0o600)
        return manifest
    except (ReleaseError, OSError):
        shutil.rmtree(output, ignore_errors=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(package(args.release, args.output), indent=2))
    except (ReleaseError, OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(str(error) if isinstance(error, ReleaseError) else
              "加密測試包檢查失敗；未顯示私密資料。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
