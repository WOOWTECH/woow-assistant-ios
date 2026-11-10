#!/bin/bash
# Official download: https://help.apple.com/itc/transporteruserguide/en.lproj/static.html
# Audited 2026-11-10: iTMSTransporter 4.3.0.4, 146739033 bytes.
# Apple's public URL is mutable: a new package must fail until its pins are reviewed.
# Install only on a fresh GitHub-hosted macOS runner; no account or key is used.
set -euo pipefail
export LC_ALL=C
umask 077

readonly PACKAGE_URL='https://itunesconnect.apple.com/WebObjects/iTunesConnect.woa/ra/resources/download/public/Transporter__OSX/bin/'
readonly PACKAGE_SHA256='12573d1a73acad29c6ba800fda807eb58ce2de559136cfab3c5fe5fe471f8094'
readonly TRANSPORTER='/usr/local/itms/bin/iTMSTransporter'

fail() { printf '%s\n' "$1" >&2; exit 1; }

mode="${1:---install}"
case "$mode" in
  --verify-only)
    [[ $# -eq 2 ]] || fail '用法：release_install_transporter.sh --verify-only 套件路徑'
    package="$2"
    [[ -f "$package" && ! -L "$package" ]] || fail '必須提供一般檔案形式的安裝套件。'
    temp_root="${TMPDIR:-/tmp}"
    ;;
  --install)
    [[ $# -le 1 ]] || fail '安裝模式不接受額外參數。'
    [[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_OS:-}" == macOS ]] \
      || fail '安裝僅限 GitHub-hosted macOS runner；本機請使用 --verify-only。'
    [[ -n "${RUNNER_TEMP:-}" && -d "$RUNNER_TEMP" ]] || fail '缺少 runner 暫存目錄。'
    # Apple's installer replaces this directory. Never overwrite another installation.
    [[ ! -e /usr/local/itms && ! -L /usr/local/itms ]] || fail '已有 Transporter 安裝；請使用乾淨的 runner。'
    temp_root="$RUNNER_TEMP"
    ;;
  *) fail '僅支援 --install 或 --verify-only 套件路徑。' ;;
esac

tool_dir="$(mktemp -d "$temp_root/woow-release-transporter.XXXXXX")"
trap 'rm -rf -- "$tool_dir"' EXIT

if [[ "$mode" == --install ]]; then
  package="$tool_dir/Transporter.pkg"
  # GET is required: this official endpoint returns 404 for HEAD requests.
  # Enforce both Content-Length and a streaming limit; never retry automatically.
  python3 - "$PACKAGE_URL" "$package" <<'PY'
import pathlib
import time
import urllib.parse
import urllib.request
import sys

class AppleHTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urllib.parse.urlsplit(newurl)
        if target.scheme != 'https' or not (target.hostname or '').endswith('.apple.com'):
            raise ValueError('Unexpected download redirect')
        return super().redirect_request(req, fp, code, msg, headers, newurl)

limit = 256 * 1024 * 1024
total = 0
started = time.monotonic()
try:
    opener = urllib.request.build_opener(AppleHTTPSRedirect())
    with opener.open(sys.argv[1], timeout=30) as response, pathlib.Path(sys.argv[2]).open('xb') as output:
        declared = response.headers.get('Content-Length')
        if declared and int(declared) > limit:
            raise ValueError('Package too large')
        while True:
            if time.monotonic() - started > 180:
                raise TimeoutError('Download deadline')
            chunk = response.read(min(1024 * 1024, limit - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise ValueError('Package too large')
            output.write(chunk)
except Exception:
    sys.exit('Transporter 下載失敗、逾時或超過 256 MiB；未安裝。')
PY
fi

actual_sha256="$(/usr/bin/shasum -a 256 "$package")"
[[ "${actual_sha256%% *}" == "$PACKAGE_SHA256" ]] || fail 'Transporter 套件 SHA-256 不符；未安裝，需重新查核 Apple 發行版本。'
/usr/sbin/pkgutil --check-signature "$package" > "$tool_dir/signature.txt" 2>&1 \
  || fail 'Transporter 安裝套件簽章驗證失敗；未安裝。'

# A valid Developer ID alone is insufficient: require the audited Apple leaf,
# its SHA-256 certificate fingerprint, and the expected Apple trust chain.
python3 - "$tool_dir/signature.txt" <<'PY'
from pathlib import Path
import re
import sys

signature = Path(sys.argv[1]).read_text()
chain = re.findall(r'^\s*\d+\. (.+)$', signature, re.MULTILINE)
leaf = re.search(r'^\s*1\. .*?SHA256 Fingerprint:\s*([A-F0-9\s]+)', signature, re.MULTILINE | re.DOTALL)
fingerprint = re.sub(r'\s+', '', leaf.group(1)) if leaf else ''
if (chain != ['Developer ID Installer: Apple Inc. - MZCD Automation (4U568XBT3J)',
              'Developer ID Certification Authority', 'Apple Root CA']
        or fingerprint != 'FC8FE65A8C41D2F1F7BA9BE3522951D985A94BF203EEDCF156248D8920B88316'
        or not re.search(r'^\s*Status: signed by a developer certificate issued by Apple for distribution\s*$',
                         signature, re.MULTILINE)):
    sys.exit('Transporter 簽署者或憑證指紋不是已查核的 Apple 安裝程式；未安裝。')
PY

printf '%s\n' 'Transporter 4.3.0.4：套件雜湊與 Apple 安裝程式簽章驗證通過。'
if [[ "$mode" == --install ]]; then
  sudo -n /usr/sbin/installer -pkg "$package" -target /
  [[ -x "$TRANSPORTER" ]] || fail '安裝完成後找不到 Transporter 執行檔。'
  printf 'Transporter 執行檔：%s\n' "$TRANSPORTER"
  python3 - "$TRANSPORTER" <<'PY'
import subprocess
import sys
try:
    subprocess.run([sys.argv[1], '-version'], timeout=180, check=True)
except (OSError, subprocess.SubprocessError):
    sys.exit('Transporter 版本啟動驗證失敗；尚未嘗試上傳。')
PY
fi
