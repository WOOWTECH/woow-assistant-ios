#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
transcript_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/woow-transcript-checks.XXXXXX")"
printf 'Transcript check artifacts: %s\n' "$transcript_build_dir"
swiftc -swift-version 5 -parse-as-library -enable-testing -emit-module -emit-library \
  -module-name AssistantModels -emit-module-path "$transcript_build_dir/AssistantModels.swiftmodule" \
  Sources/AssistantModels/*.swift -o "$transcript_build_dir/libAssistantModels.dylib"
swiftc -swift-version 5 -parse-as-library -enable-testing -emit-module -emit-library \
  -I "$transcript_build_dir" -L "$transcript_build_dir" -lAssistantModels \
  -module-name AssistantSkills -emit-module-path "$transcript_build_dir/AssistantSkills.swiftmodule" \
  Sources/AssistantSkills/*.swift -o "$transcript_build_dir/libAssistantSkills.dylib"
swiftc -swift-version 5 -D TRANSCRIPT_SMOKE -parse-as-library \
  -I "$transcript_build_dir" -L "$transcript_build_dir" -lAssistantModels -lAssistantSkills \
  -Xlinker -rpath -Xlinker "$transcript_build_dir" \
  Tests/AssistantSkillsTests/Transcript*.swift -o "$transcript_build_dir/transcript-checks"
"$transcript_build_dir/transcript-checks" Sources/AssistantSkills/Resources/MikaBundledSkills.json \
  | tee "$transcript_build_dir/results.log"
swiftc -frontend -parse Sources/App/TranscriptSession.swift Sources/App/TranscriptView.swift
cat > "$transcript_build_dir/ModelAccess.swift" <<'SWIFT'
import AssistantModels
// Compile-only host signature; no replacement runtime or UI test configuration.
struct ModelAccess {
    let client: any ChatModelClient
    let configuration: ModelConfiguration
    let key: String
}
SWIFT
swiftc -swift-version 5 -typecheck -I "$transcript_build_dir" \
  Sources/App/TranscriptSession.swift "$transcript_build_dir/ModelAccess.swift"
