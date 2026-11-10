#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile_build=$(mktemp -d "${TMPDIR:-/tmp}/woow-profile-core.XXXXXX")
trap 'rm -rf "$profile_build"' EXIT
swiftc -emit-module -emit-library -enable-testing -module-name AssistantModels \
  Sources/AssistantModels/*.swift -o "$profile_build/libAssistantModels.dylib" \
  -emit-module-path "$profile_build/AssistantModels.swiftmodule"
swiftc -emit-module -emit-library -enable-testing -module-name AssistantMemory \
  -I "$profile_build" -L "$profile_build" -lAssistantModels \
  Sources/AssistantMemory/*.swift -o "$profile_build/libAssistantMemory.dylib" \
  -emit-module-path "$profile_build/AssistantMemory.swiftmodule"
swiftc -D USER_PROFILE_STANDALONE -parse-as-library \
  -I "$profile_build" -L "$profile_build" -lAssistantModels -lAssistantMemory \
  -Xlinker -rpath -Xlinker "$profile_build" \
  Tests/AssistantMemoryTests/UserProfileStateTests.swift -o "$profile_build/profile-checks"
"$profile_build/profile-checks"
