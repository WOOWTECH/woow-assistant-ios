#!/usr/bin/env python3
"""Explicit App Store Connect upload of this run's verified signed export.

Acceptance by Transporter is not processing completion or TestFlight availability.
No retries, tester invitations, store submission, or signing-material creation.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

from release_ios import BUNDLE_ID, ReleaseError, SECRET_NAMES

UPLOAD_SECRETS = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_BASE64")
TRANSPORTER = Path("/usr/local/itms/bin/iTMSTransporter")


def credentials(env):
    if any(not env.get(name, "").strip() for name in UPLOAD_SECRETS):
        raise ReleaseError("缺少 App Store Connect 上傳 secrets；尚未嘗試上傳。")
    key_id = env["ASC_KEY_ID"].strip()
    issuer = env["ASC_ISSUER_ID"].strip()
    if not re.fullmatch(r"[A-Z0-9]{10}", key_id):
        raise ReleaseError("ASC_KEY_ID 格式不符。")
    try:
        uuid.UUID(issuer)
        key = base64.b64decode(env["ASC_PRIVATE_KEY_BASE64"], validate=True)
    except (ValueError, TypeError):
        raise ReleaseError("App Store Connect 認證格式不符。") from None
    if len(key) > 16384 or not re.fullmatch(
            rb"-----BEGIN PRIVATE KEY-----\r?\n[A-Za-z0-9+/=\r\n]+-----END PRIVATE KEY-----\s*", key):
        raise ReleaseError("私鑰不是預期的 PKCS#8 PEM；尚未嘗試上傳。")
    return key_id, issuer, key


def verified_export(folder, method="app-store-connect"):
    if method not in ("app-store-connect", "release-testing"):
        raise ReleaseError("不支援的簽章匯出類型。")
    report = json.loads((folder / "report.json").read_text())
    if not (isinstance(report, dict) and report.get("signature_verified") is True
            and report.get("bundle_id") == BUNDLE_ID
            and report.get("artifact_kind") == "signed-local-export"
            and report.get("export_method") == method):
        raise ReleaseError("只接受同一次建置已驗證且匯出模式相符的簽章 IPA。")
    ipas = list((folder / "export").glob("*.ipa"))
    if len(ipas) != 1 or ipas[0].is_symlink() or not ipas[0].is_file():
        raise ReleaseError("找不到唯一、一般檔案形式的 IPA。")
    digest = hashlib.sha256()
    with ipas[0].open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != report.get("ipa_sha256"):
        raise ReleaseError("IPA 與已驗證簽章產物的 SHA-256 不符。")
    return ipas[0].resolve(), digest.hexdigest()


def upload(folder):
    # A prior attempt, even one whose completion is unknown, must not be sent
    # again implicitly. A fresh CI build has its own unique build number.
    output = folder / "upload-report.json"
    if output.exists():
        raise ReleaseError("已有上傳紀錄；請先查核 Apple 狀態，不會自動重送。")
    if not TRANSPORTER.is_file() or not os.access(TRANSPORTER, os.X_OK):
        raise ReleaseError("尚未安裝 Apple Transporter；尚未嘗試上傳。")
    key_id, issuer, key = credentials(os.environ)
    ipa, digest = verified_export(folder)
    report = {"bundle_id": BUNDLE_ID, "ipa_sha256": digest,
              "upload_attempted": False, "upload_accepted": None,
              "processing_verified": False, "testflight_available": None}

    def save():
        temporary = folder / "upload-report.json.tmp"
        temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(output)

    with tempfile.TemporaryDirectory(prefix="woow-asc-") as directory:
        private = Path(directory) / "private_keys"
        private.mkdir(mode=0o700)
        key_file = private / ("AuthKey_" + key_id + ".p8")
        with key_file.open("xb") as handle:
            os.chmod(key_file, 0o600)
            handle.write(key)
        # Transporter documents cwd/private_keys as its first lookup path.
        # Do not copy keys into HOME or expose secret env vars to the tool.
        env = {k: v for k, v in os.environ.items() if k not in SECRET_NAMES + UPLOAD_SECRETS}
        report["upload_attempted"] = True
        save()
        try:
            completed = subprocess.run([str(TRANSPORTER), "-m", "upload", "-assetFile", str(ipa),
                "-apiKey", key_id, "-apiIssuer", issuer], cwd=directory, env=env,
                capture_output=True, timeout=1800)
        except subprocess.TimeoutExpired:
            report["timed_out"] = True
            raise ReleaseError("上傳逾時，Apple 是否已接收尚未確認；請查核後再決定，不自動重送。") from None
        except OSError:
            report["upload_attempted"] = False
            raise ReleaseError("無法啟動 Apple 上傳工具。") from None
        else:
            report["exit_code"] = completed.returncode
            report["upload_accepted"] = True if completed.returncode == 0 else None
            if completed.returncode:
                raise ReleaseError("Apple 上傳工具未回報成功；請在 App Store Connect 查核，不自動重送。")
        finally:
            # Raw Transporter output can contain account details; never publish
            # it in Actions logs or public artifacts. Keep fixed outcome fields.
            save()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, default=Path("build/release"))
    args = parser.parse_args()
    try:
        print(json.dumps(upload(args.release.resolve()), ensure_ascii=False, indent=2))
    except (ReleaseError, OSError, ValueError, TypeError):
        error = sys.exc_info()[1]
        print(str(error) if isinstance(error, ReleaseError) else "上傳前置檢查失敗；未顯示私密內容。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
