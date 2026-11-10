#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile_tool_build=$(mktemp -d "${TMPDIR:-/tmp}/woow-profile-tool.XXXXXX")
trap 'rm -rf "$profile_tool_build"' EXIT
swiftc -warnings-as-errors -emit-module -emit-library -enable-testing -module-name AssistantModels \
  Sources/AssistantModels/*.swift -o "$profile_tool_build/libAssistantModels.dylib" \
  -emit-module-path "$profile_tool_build/AssistantModels.swiftmodule"
swiftc -warnings-as-errors -emit-module -emit-library -enable-testing -module-name AssistantMemory \
  -I "$profile_tool_build" -L "$profile_tool_build" -lAssistantModels \
  Sources/AssistantMemory/*.swift -o "$profile_tool_build/libAssistantMemory.dylib" \
  -emit-module-path "$profile_tool_build/AssistantMemory.swiftmodule"
swiftc -warnings-as-errors -D USER_PROFILE_TOOL_STANDALONE -parse-as-library \
  -I "$profile_tool_build" -L "$profile_tool_build" -lAssistantModels -lAssistantMemory \
  -Xlinker -rpath -Xlinker "$profile_tool_build" \
  Tests/AssistantMemoryTests/UserProfileToolTests.swift -o "$profile_tool_build/profile-tool-checks"
"$profile_tool_build/profile-tool-checks"
