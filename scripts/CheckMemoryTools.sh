#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
memory_tools_build=$(mktemp -d "${TMPDIR:-/tmp}/woow-memory-tools.XXXXXX")
trap 'rm -rf "$memory_tools_build"' EXIT
swiftc -warnings-as-errors -emit-module -emit-library -enable-testing -module-name AssistantModels \
  Sources/AssistantModels/*.swift -o "$memory_tools_build/libAssistantModels.dylib" \
  -emit-module-path "$memory_tools_build/AssistantModels.swiftmodule"
swiftc -warnings-as-errors -emit-module -emit-library -enable-testing -module-name AssistantMemory \
  -I "$memory_tools_build" -L "$memory_tools_build" -lAssistantModels \
  Sources/AssistantMemory/*.swift -o "$memory_tools_build/libAssistantMemory.dylib" \
  -emit-module-path "$memory_tools_build/AssistantMemory.swiftmodule"
swiftc -warnings-as-errors -D MEMORY_TOOLS_STANDALONE -parse-as-library \
  -I "$memory_tools_build" -L "$memory_tools_build" -lAssistantModels -lAssistantMemory \
  -Xlinker -rpath -Xlinker "$memory_tools_build" \
  Tests/AssistantMemoryTests/MemoryToolsTests.swift -o "$memory_tools_build/memory-tool-checks"
"$memory_tools_build/memory-tool-checks"
# The shared parser/grounding refactor must retain all prior profile assertions.
swiftc -warnings-as-errors -D USER_PROFILE_TOOL_STANDALONE -parse-as-library \
  -I "$memory_tools_build" -L "$memory_tools_build" -lAssistantModels -lAssistantMemory \
  -Xlinker -rpath -Xlinker "$memory_tools_build" \
  Tests/AssistantMemoryTests/UserProfileToolTests.swift -o "$memory_tools_build/profile-tool-checks"
"$memory_tools_build/profile-tool-checks"
# Reuse the existing state/extraction regression assertions against the same module.
swiftc -warnings-as-errors -parse-as-library \
  -I "$memory_tools_build" -L "$memory_tools_build" -lAssistantModels -lAssistantMemory \
  -Xlinker -rpath -Xlinker "$memory_tools_build" \
  Tests/AssistantMemoryTests/MemoryChecks.swift scripts/MemoryCoreChecks.swift -o "$memory_tools_build/memory-core-checks"
"$memory_tools_build/memory-core-checks"
