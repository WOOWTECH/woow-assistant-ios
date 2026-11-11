#!/usr/bin/env python3
"""Offline device build / signed export. Never contacts App Store Connect.

Python 3.9+, macOS + full Xcode + XcodeGen. Signing material comes only from
environment secrets; diagnostics deliberately omit subprocess output/arguments.
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid
from contextlib import contextmanager

BUNDLE_ID = "io.woowtech.assistant"
SCHEME = "WoowAssistant"
SECRET_NAMES = (
    "IOS_SIGNING_CERTIFICATE_BASE64", "IOS_SIGNING_CERTIFICATE_PASSWORD",
    "IOS_PROVISION_PROFILE_BASE64", "IOS_TEAM_ID", "IOS_KEYCHAIN_PASSWORD",
)


class ReleaseError(Exception):
    pass


class ReleaseToolError(ReleaseError):
    """Closed published metadata, without command arguments or child output."""
    def __init__(self, message, category):
        if category not in {"timeout", "launchFailed", "nonzeroExit"}:
            raise ValueError("Unknown tool failure category")
        super().__init__(message)
        self.category = category


def run(args, label, timeout=120, env=None, diagnostic_log=None):
    """Do not echo commands: security arguments may contain passwords."""
    if env is None:
        env = {k: v for k, v in os.environ.items() if k not in SECRET_NAMES}
    try:
        result = subprocess.run(args, capture_output=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired as error:
        if diagnostic_log is not None:
            diagnostic_log.write_bytes((error.stdout or b"") + (error.stderr or b""))
        raise ReleaseToolError(label + "：工具執行逾時。", "timeout") from None
    except OSError:
        raise ReleaseToolError(label + "：工具不存在或執行逾時。", "launchFailed") from None
    if diagnostic_log is not None:
        diagnostic_log.write_bytes(result.stdout + result.stderr)
    if result.returncode:
        raise ReleaseToolError(label + "：失敗（退出碼 %d；未輸出可能含憑證的內容）。" % result.returncode, "nonzeroExit")
    return result.stdout


def version(value):
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", str(value)):
        raise ReleaseError("版本資料格式無效。")
    return tuple(int(x) for x in value.split(".")) + (0,) * (3 - len(value.split(".")))


def require_secrets(env):
    missing = [name for name in SECRET_NAMES if not env.get(name, "").strip()]
    if missing:
        raise ReleaseError("缺少 GitHub Actions secrets：" + ", ".join(missing))
    if not re.fullmatch(r"[A-Z0-9]{10}", env["IOS_TEAM_ID"]):
        raise ReleaseError("IOS_TEAM_ID 必須為 10 位英數字元。")


def decode_secret(value, label):
    try:
        data = base64.b64decode("".join(value.split()), validate=True)
    except (ValueError, base64.binascii.Error):
        raise ReleaseError(label + "：不是有效的 Base64。") from None
    if not data:
        raise ReleaseError(label + "：不可為空。")
    return data


def validate_profile(profile, team, method, now=None):
    """Require an explicit app ID and distribution profile; no wildcard fallback."""
    now = now or dt.datetime.now(dt.timezone.utc)
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, dt.datetime):
        raise ReleaseError("描述檔缺少到期日。")
    if expiry.replace(tzinfo=dt.timezone.utc) <= now:
        raise ReleaseError("描述檔已到期；需提供仍有效的描述檔。")
    entitlements = profile.get("Entitlements", {})
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    app_ids = [prefix + "." + BUNDLE_ID for prefix in prefixes if isinstance(prefix, str)]
    if (profile.get("TeamIdentifier") != [team]
            or entitlements.get("com.apple.developer.team-identifier") != team
            or entitlements.get("application-identifier") not in app_ids):
        raise ReleaseError("描述檔的 Team／明確 App ID 與專案不符。")
    if "iOS" not in profile.get("Platform", []):
        raise ReleaseError("描述檔不支援 iOS。")
    if entitlements.get("get-task-allow") is not False or profile.get("ProvisionsAllDevices"):
        raise ReleaseError("僅接受 App Store 或 Ad Hoc distribution 描述檔。")
    has_devices = bool(profile.get("ProvisionedDevices"))
    if method not in ("app-store-connect", "release-testing"):
        raise ReleaseError("不支援此匯出方式。")
    if has_devices != (method == "release-testing"):
        raise ReleaseError("描述檔類型與匯出方式不符。")
    try:
        profile_id = str(uuid.UUID(profile["UUID"])).upper()
    except (KeyError, ValueError, TypeError, AttributeError):
        raise ReleaseError("描述檔 UUID 無效。") from None
    certs = profile.get("DeveloperCertificates", [])
    if not certs or not all(isinstance(cert, bytes) for cert in certs):
        raise ReleaseError("描述檔缺少簽章憑證。")
    return profile_id, {hashlib.sha1(cert).hexdigest().upper() for cert in certs}


def matching_identity(output, allowed):
    matches = re.findall(r'^\s*\d+\) ([A-Fa-f0-9]{40}) "(Apple Distribution|iPhone Distribution)[^"\n]*"', output, re.M)
    identities = {digest.upper() for digest, _ in matches} & allowed
    if len(identities) != 1:
        raise ReleaseError("需有且僅有一個與描述檔相符的有效 distribution 憑證及私鑰。")
    return identities.pop()


def toolchain(signed=False):
    if signed:
        require_secrets(os.environ)
    xcode = run(["xcodebuild", "-version"], "需要完整 Xcode，Command Line Tools 不足").decode().strip()
    sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], "需要 iPhoneOS SDK").decode().strip()
    if signed and version(sdk) < (26, 0, 0):
        raise ReleaseError("簽章匯出要求 iOS 26 SDK 以上；請使用 Xcode 26 以上。")
    if not shutil.which("xcodegen"):
        raise ReleaseError("缺少 XcodeGen；請使用流程中固定版本與 SHA-256 檢查的安裝步驟。")
    return {"xcode": xcode, "iphoneos_sdk": sdk}


def configure_signing(project, team, identity, profile_id):
    """Modify only the disposable generated project, not project.yml.

    App provisioning must NOT be applied globally to dependent frameworks.
    """
    objects = project["objects"]
    found = False
    for target in objects.values():
        if target.get("isa") != "PBXNativeTarget":
            continue
        app = target.get("productType") == "com.apple.product-type.application"
        if app and target.get("name") != SCHEME:
            raise ReleaseError("目前僅支援單一 WoowAssistant App；其他 App 需要獨立描述檔。")
        if target.get("productType") == "com.apple.product-type.app-extension":
            raise ReleaseError("App extension 需要獨立簽章設定，目前不支援。")
        configs = objects[target["buildConfigurationList"]]["buildConfigurations"]
        for config_id in configs:
            config = objects[config_id]
            if config["name"] != "Release":
                continue
            settings = config.setdefault("buildSettings", {})
            settings.update(CODE_SIGN_STYLE="Manual", DEVELOPMENT_TEAM=team,
                            CODE_SIGN_IDENTITY=identity, PROVISIONING_PROFILE="",
                            PROVISIONING_PROFILE_SPECIFIER=profile_id if app else "")
            if app:
                if settings.get("PRODUCT_BUNDLE_IDENTIFIER") != BUNDLE_ID:
                    raise ReleaseError("App Bundle ID 與簽章設定不符。")
                found = True
    if not found:
        raise ReleaseError("找不到 App 的 Release 設定。")


def verify_settings(rows):
    apps = [r for r in rows if r.get("target") == SCHEME]
    if len(apps) != 1:
        raise ReleaseError("找不到唯一的 App 建置設定。")
    for row in rows:
        settings = row.get("buildSettings", {})
        minimum = settings.get("IPHONEOS_DEPLOYMENT_TARGET")
        if minimum and version(minimum) > (17, 0, 0):
            raise ReleaseError("建置目標最低版本高於 iOS 17.0。")
    app = apps[0]["buildSettings"]
    if app.get("PRODUCT_BUNDLE_IDENTIFIER") != BUNDLE_ID or version(app.get("IPHONEOS_DEPLOYMENT_TARGET", "")) != (17, 0, 0):
        raise ReleaseError("App 必須保留指定 Bundle ID 與 iOS 17.0 最低版本。")


def verify_macho(output):
    # LC_BUILD_VERSION also contains a linker tool's `version` (e.g. 1230.1).
    # That tool version is not an OS requirement. Parse each load command by kind.
    minimums = []
    for kind, section in re.findall(r"cmd LC_(BUILD_VERSION|VERSION_MIN_IPHONEOS)\b(.*?)(?=cmd LC_|\Z)", output, re.S):
        if kind == "BUILD_VERSION":
            if re.findall(r"^\s*platform\s+(\S+)\s*$", section, re.M) not in [["IOS"], ["2"]]:
                raise ReleaseError("Mach-O 不是 iPhoneOS 平台。")
            field = "minos"
        else:
            field = "version"
        values = re.findall(r"^\s*" + field + r"\s+(\d+\.\d+(?:\.\d+)?)\s*$", section, re.M)
        if len(values) != 1:
            raise ReleaseError("Mach-O 最低系統版本欄位缺少或不唯一。")
        minimums.extend(values)
    if not minimums or any(version(v) > (17, 0, 0) for v in minimums):
        raise ReleaseError("Mach-O 最低系統版本無法驗證或高於 iOS 17.0。")


def verify_required_reasons(app):
    # Audit the packaged file, not merely the repository resource. These are
    # the two directly used categories: app settings and elapsed-time timers.
    try:
        privacy = plistlib.loads((app / "PrivacyInfo.xcprivacy").read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise ReleaseError("App 缺少可讀取的 PrivacyInfo.xcprivacy。") from None
    entries = privacy.get("NSPrivacyAccessedAPITypes") if isinstance(privacy, dict) else None
    if not isinstance(entries, list) or any(not isinstance(entry, dict) for entry in entries):
        raise ReleaseError("App 的 required-reason API 宣告格式不正確。")
    for category, reason in [("NSPrivacyAccessedAPICategoryUserDefaults", "CA92.1"),
                             ("NSPrivacyAccessedAPICategorySystemBootTime", "35F9.1"),
                             ("NSPrivacyAccessedAPICategoryFileTimestamp", "3B52.1")]:
        matches = [entry for entry in entries if entry.get("NSPrivacyAccessedAPIType") == category]
        reasons = matches[0].get("NSPrivacyAccessedAPITypeReasons") if len(matches) == 1 else None
        if not isinstance(reasons, list) or reason not in reasons or any(not isinstance(value, str) for value in reasons):
            raise ReleaseError("App 缺少正確且唯一的 required-reason API 宣告：" + category)


def verify_app(app, signed=False, identity=None, expected_build_number=None):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if expected_build_number is not None and info.get("CFBundleVersion") != expected_build_number:
        raise ReleaseError("實際產物建置編號與指定發行編號不符。")
    if (info.get("CFBundleIdentifier") != BUNDLE_ID
            or version(info.get("MinimumOSVersion", "")) != (17, 0, 0)
            or info.get("DTPlatformName") != "iphoneos"):
        raise ReleaseError("App 不是最低 iOS 17.0 的 iPhoneOS 產物。")
    # Inspect the built product in every mode, including the extracted IPA.
    # Even an empty ATS dictionary is unexpected in the Release configuration.
    if "NSAppTransportSecurity" in info:
        raise ReleaseError("Release App 的 Info.plist 不得含 NSAppTransportSecurity；請檢查 Debug 測試例外是否混入產物。")
    for key in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription"):
        value = info.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ReleaseError("Release App 缺少網站媒體權限用途說明：" + key)
    if not all(info.get(key) is True for key in ("UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace")):
        raise ReleaseError("Release App 缺少系統檔案選擇器所需的 Documents 共享設定。")
    verify_required_reasons(app)
    binaries = [app / info["CFBundleExecutable"]]
    for framework in (app / "Frameworks").glob("*.framework"):
        data = plistlib.loads((framework / "Info.plist").read_bytes())
        binaries.append(framework / data["CFBundleExecutable"])
    binaries.extend((app / "Frameworks").glob("*.dylib"))
    for binary in binaries:
        arches = run(["xcrun", "lipo", "-archs", str(binary)], "檢查裝置架構").decode().split()
        if "arm64" not in arches or "x86_64" in arches:
            raise ReleaseError("裝置產物必須包含 arm64，且不可包含 x86_64。")
        loads = run(["xcrun", "otool", "-l", str(binary)], "檢查 Mach-O 最低系統版本").decode()
        sections = re.split(r"Load command \d+", loads)
        deployment = "\n".join(s for s in sections if re.search(r"cmd LC_(BUILD_VERSION|VERSION_MIN_IPHONEOS)\b", s))
        if re.search(r"platform\s+(?:IOSSIMULATOR|7)\b", deployment):
            raise ReleaseError("偵測到模擬器二進位檔。")
        try:
            verify_macho(deployment)
        except ReleaseError as error:
            raise ReleaseError(str(error) + " Binary: " + str(binary.relative_to(app)) + "\n" + deployment.strip()) from None
    if signed:
        if not (app / "embedded.mobileprovision").is_file():
            raise ReleaseError("簽章 App 缺少內嵌描述檔。")
        run(["codesign", "--verify", "--deep", "--strict", str(app)], "驗證 App 與內嵌程式簽章")
        # codesign --verify alone also accepts ad-hoc signatures. Require the
        # actual certificate used by this build, not merely an intact seal.
        with tempfile.TemporaryDirectory(prefix="woow-cert-check-") as directory:
            prefix = str(Path(directory) / "cert")
            run(["codesign", "-d", "--extract-certificates", prefix, str(app)], "驗證簽章憑證")
            leaf = Path(prefix + "0")
            if not identity or not leaf.is_file() or hashlib.sha1(leaf.read_bytes()).hexdigest().upper() != identity:
                raise ReleaseError("App 未使用指定 distribution 憑證簽章。")
    return {"bundle_id": BUNDLE_ID, "minimum_os": "17.0", "platform": "iphoneos",
            "verified_binary_count": len(binaries), "signature_verified": signed,
            "ats_key_absent": True, "native_documents_enabled": True,
            "browser_media_purpose_strings_verified": True,
            "required_reason_entries_verified": True}


@contextmanager
def signing_material(method):
    require_secrets(os.environ)
    env = os.environ
    with tempfile.TemporaryDirectory(prefix="woow-signing-") as directory:
        folder = Path(directory)
        certificate = folder / "certificate.p12"
        profile_file = folder / "profile.mobileprovision"
        certificate.write_bytes(decode_secret(env[SECRET_NAMES[0]], SECRET_NAMES[0]))
        profile_file.write_bytes(decode_secret(env[SECRET_NAMES[2]], SECRET_NAMES[2]))
        certificate.chmod(0o600)
        profile_file.chmod(0o600)
        profile = plistlib.loads(run(["security", "cms", "-D", "-i", str(profile_file)], "解碼描述檔"))
        profile_id, allowed = validate_profile(profile, env["IOS_TEAM_ID"], method)
        keychain = folder / "signing.keychain-db"
        password = env["IOS_KEYCHAIN_PASSWORD"]
        original = shlex.split(run(["security", "list-keychains", "-d", "user"], "讀取鑰匙圈搜尋清單").decode())
        installed = []
        try:
            run(["security", "create-keychain", "-p", password, str(keychain)], "建立暫存鑰匙圈")
            run(["security", "set-keychain-settings", "-lut", "7200", str(keychain)], "設定暫存鑰匙圈")
            run(["security", "unlock-keychain", "-p", password, str(keychain)], "解鎖暫存鑰匙圈")
            run(["security", "import", str(certificate), "-P", env[SECRET_NAMES[1]], "-k", str(keychain),
                 "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], "匯入既有簽章憑證")
            run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain)], "允許建置工具使用暫存金鑰")
            run(["security", "list-keychains", "-d", "user", "-s", str(keychain)] + original, "設定暫存搜尋清單")
            identity = matching_identity(run(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)], "驗證可用簽章身分").decode(), allowed)
            for relative in ("Library/MobileDevice/Provisioning Profiles", "Library/Developer/Xcode/UserData/Provisioning Profiles"):
                destination = Path.home() / relative / (profile_id + ".mobileprovision")
                destination.parent.mkdir(parents=True, exist_ok=True)
                # Exclusive creation preserves any pre-existing user profile.
                try:
                    with destination.open("xb") as handle:
                        installed.append(destination)
                        handle.write(profile_file.read_bytes())
                    destination.chmod(0o600)
                except FileExistsError:
                    raise ReleaseError("同 UUID 描述檔已存在；拒絕覆寫。請使用乾淨的 CI runner。") from None
            yield {"team": env["IOS_TEAM_ID"], "identity": identity, "profile_id": profile_id, "keychain": str(keychain)}
        finally:
            errors = []
            for args in (["security", "list-keychains", "-d", "user", "-s"] + original,
                         ["security", "delete-keychain", str(keychain)]):
                try:
                    run(args, "清理暫存簽章資料")
                except ReleaseError as error:
                    errors.append(str(error))
            for path in installed:
                path.unlink(missing_ok=True)
            if errors:
                raise ReleaseError("暫存鑰匙圈清理未完整成功；需由 runner 管理員檢查。")


def generate_project(root, output):
    run(["xcodegen", "generate", "--spec", str(root / "project.yml"), "--project", str(output)], "產生獨立建置專案")
    # XcodeGen rebases source paths, but not an explicit INFOPLIST_FILE setting.
    # Keep the isolated Debug project usable without changing Release settings.
    configuration = output / "Configuration"
    configuration.mkdir(exist_ok=True)
    for name in ("Info-Debug.plist", "Info-Release.plist"):
        shutil.copyfile(root / "Configuration" / name, configuration / name)
    return output / (SCHEME + ".xcodeproj")


def build(root, output, signed, method, build_number=None):
    if build_number is not None and not re.fullmatch(r"[1-9][0-9]{0,17}", build_number):
        raise ReleaseError("建置編號必須是 1 至 18 位正整數。")
    metadata = toolchain(signed)
    output.mkdir(parents=True, exist_ok=False)  # never reuse stale products
    project = generate_project(root, output)
    common = ["xcodebuild", "-project", str(project), "-scheme", SCHEME, "-configuration", "Release",
              "-sdk", "iphoneos", "-destination", "generic/platform=iOS",
              "-derivedDataPath", str(output / "DerivedData")]
    if build_number is not None:
        common.append("CURRENT_PROJECT_VERSION=" + build_number)
        metadata["build_number"] = build_number
    # Do not leak signing secrets to project build phases / dependency tools.
    child_env = {k: v for k, v in os.environ.items() if k not in SECRET_NAMES}
    verify_settings(json.loads(run(common + ["-showBuildSettings", "-json"], "檢查實際最低系統設定", env=child_env)))
    if not signed:
        run(common + ["build", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY="],
            "未簽章裝置建置", timeout=2400, env=child_env, diagnostic_log=output / "device-build.log")
        app = output / "DerivedData/Build/Products/Release-iphoneos/WoowAssistant.app"
        metadata.update(verify_app(app, expected_build_number=build_number))
        metadata["artifact_kind"] = "unsigned-device-build-not-installable"
    else:
        with signing_material(method) as signing:
            pbx = project / "project.pbxproj"
            graph = json.loads(run(["plutil", "-convert", "json", "-o", "-", str(pbx)], "讀取產生的專案"))
            configure_signing(graph, signing["team"], signing["identity"], signing["profile_id"])
            pbx.write_bytes(plistlib.dumps(graph))
            archive = output / "WoowAssistant.xcarchive"
            run(common + ["-archivePath", str(archive), "archive", "CODE_SIGNING_ALLOWED=YES",
                          "OTHER_CODE_SIGN_FLAGS=--keychain " + signing["keychain"]], "簽章封存", timeout=2400, env=child_env)
            verify_app(archive / "Products/Applications/WoowAssistant.app", signed=True, identity=signing["identity"], expected_build_number=build_number)
            options = {"method": method, "destination": "export", "signingStyle": "manual",
                       "teamID": signing["team"], "signingCertificate": signing["identity"],
                       "provisioningProfiles": {BUNDLE_ID: signing["profile_id"]},
                       "manageAppVersionAndBuildNumber": False, "stripSwiftSymbols": True,
                       "uploadSymbols": False}
            # This file and profile metadata are deliberately not CI artifacts.
            with tempfile.TemporaryDirectory(prefix="woow-export-") as private:
                options_path = Path(private) / "ExportOptions.plist"
                options_path.write_bytes(plistlib.dumps(options))
                run(["xcodebuild", "-exportArchive", "-archivePath", str(archive), "-exportPath", str(output / "export"),
                     "-exportOptionsPlist", str(options_path)], "本地匯出簽章 IPA", timeout=1200, env=child_env)
                ipas = list((output / "export").glob("*.ipa"))
                if len(ipas) != 1:
                    raise ReleaseError("匯出未產生唯一的簽章 IPA。")
                expanded = Path(private) / "expanded"
                run(["ditto", "-x", "-k", str(ipas[0]), str(expanded)], "檢查匯出產物")
                apps = list((expanded / "Payload").glob("*.app"))
                if len(apps) != 1:
                    raise ReleaseError("IPA 中找不到唯一的 App。")
                metadata.update(verify_app(apps[0], signed=True, identity=signing["identity"], expected_build_number=build_number))
                metadata["ipa_sha256"] = hashlib.sha256(ipas[0].read_bytes()).hexdigest()
            metadata.update(artifact_kind="signed-local-export", export_method=method)
    metadata.update(runtime_tested=False, uploaded=False)
    (output / "report.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["preflight", "build"])
    parser.add_argument("--signed", action="store_true")
    parser.add_argument("--export-method", choices=["app-store-connect", "release-testing"], default="app-store-connect")
    parser.add_argument("--output", type=Path, default=Path("build/release"))
    parser.add_argument("--build-number", help="Unique numeric build number for a signed delivery")
    args = parser.parse_args()
    try:
        if args.command == "preflight":
            result = toolchain(args.signed)
            result["signing_material_verified"] = False
            if args.signed:
                with signing_material(args.export_method):
                    result["signing_material_verified"] = True
        else:
            result = build(Path(__file__).resolve().parents[1], args.output.resolve(), args.signed, args.export_method, args.build_number)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (ReleaseError, OSError, ValueError, KeyError, plistlib.InvalidFileException):
        error = sys.exc_info()[1]
        print(str(error) if isinstance(error, ReleaseError) else "發佈檢查失敗：輸入或產物格式不符；未顯示私密資料。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
