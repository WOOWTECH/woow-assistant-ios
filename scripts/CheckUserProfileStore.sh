#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile_build=$(mktemp -d "${TMPDIR:-/tmp}/woow-profile-store.XXXXXX")
trap 'rm -rf "$profile_build"' EXIT
swiftc -emit-module -emit-library -module-name AssistantModels \
  Sources/AssistantModels/*.swift -o "$profile_build/libAssistantModels.dylib" \
  -emit-module-path "$profile_build/AssistantModels.swiftmodule"
for profile_module in AssistantMemory AssistantSkills AssistantPersistence; do
  swiftc -emit-module -emit-library -module-name "$profile_module" \
    -I "$profile_build" -L "$profile_build" -lAssistantModels \
    Sources/"$profile_module"/*.swift -o "$profile_build/lib$profile_module.dylib" \
    -emit-module-path "$profile_build/$profile_module.swiftmodule"
done
swiftc -emit-module -emit-library -module-name AssistantBrowser \
  -I "$profile_build" -L "$profile_build" -lAssistantModels -lAssistantSkills \
  Sources/AssistantBrowser/*.swift -o "$profile_build/libAssistantBrowser.dylib" \
  -emit-module-path "$profile_build/AssistantBrowser.swiftmodule"
swiftc -D USER_PROFILE_STORE_STANDALONE -parse-as-library -I "$profile_build" -L "$profile_build" \
  -lAssistantModels -lAssistantMemory -lAssistantSkills -lAssistantPersistence -lAssistantBrowser \
  -Xlinker -rpath -Xlinker "$profile_build" \
  Sources/App/LearningStore.swift Sources/App/LearningKeychainStore.swift \
  Tests/AssistantSkillsTests/UserProfilePersistenceTests.swift \
  scripts/CheckUserProfileStore.swift -o "$profile_build/profile-store-checks"
"$profile_build/profile-store-checks"
