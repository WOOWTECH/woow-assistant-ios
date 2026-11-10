#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile_chat_build=$(mktemp -d "${TMPDIR:-/tmp}/woow-profile-chat.XXXXXX")
trap 'rm -rf "$profile_chat_build"' EXIT
swiftc -emit-module -emit-library -module-name AssistantModels \
  Sources/AssistantModels/*.swift -o "$profile_chat_build/libAssistantModels.dylib" \
  -emit-module-path "$profile_chat_build/AssistantModels.swiftmodule"
swiftc -D PROFILE_CHAT_STANDALONE -parse-as-library -warnings-as-errors \
  -I "$profile_chat_build" -L "$profile_chat_build" -lAssistantModels \
  -Xlinker -rpath -Xlinker "$profile_chat_build" \
  Sources/AssistantMemory/UserProfileChatFlow.swift \
  Tests/AssistantMemoryTests/UserProfileChatFlowTests.swift -o "$profile_chat_build/checks"
"$profile_chat_build/checks"
