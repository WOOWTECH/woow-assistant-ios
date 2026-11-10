#!/bin/bash
set -euo pipefail
: "${RUNNER_TEMP:?需要 GitHub runner 的暫存目錄}"
: "${GITHUB_PATH:?需要 GitHub Actions PATH 檔案}"
tool_dir="$(mktemp -d "$RUNNER_TEMP/woow-release-xcodegen.XXXXXX")"
curl --fail --location --retry 3 --max-time 120 \
  https://github.com/yonaskolb/XcodeGen/releases/download/2.44.1/xcodegen.artifactbundle.zip \
  --output "$tool_dir/xcodegen.artifactbundle.zip"
(cd "$tool_dir" && echo 'cfa4e1ee82fc4c95bf7bd8f7db1fda6bd073605c76a8d5cbce50c54a81867eb2  xcodegen.artifactbundle.zip' | shasum -a 256 --check)
unzip -q "$tool_dir/xcodegen.artifactbundle.zip" -d "$tool_dir"
echo "$tool_dir/xcodegen.artifactbundle/xcodegen-2.44.1-macosx/bin" >> "$GITHUB_PATH"
