#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
self_config_build=$(mktemp -d "${TMPDIR:-/tmp}/woow-self-configuration.XXXXXX")
trap 'rm -rf "$self_config_build"' EXIT
swiftc -emit-module -emit-library -enable-testing -module-name AssistantModels \
  Sources/AssistantModels/*.swift -o "$self_config_build/libAssistantModels.dylib" \
  -emit-module-path "$self_config_build/AssistantModels.swiftmodule"
swiftc -emit-module -emit-library -enable-testing -module-name AssistantSkills \
  -I "$self_config_build" -L "$self_config_build" -lAssistantModels \
  Sources/AssistantSkills/SelfConfiguration*.swift \
  -o "$self_config_build/libAssistantSkills.dylib" \
  -emit-module-path "$self_config_build/AssistantSkills.swiftmodule"
swiftc -D SELF_CONFIGURATION_SMOKE -parse-as-library \
  -I "$self_config_build" -L "$self_config_build" -lAssistantModels -lAssistantSkills \
  -Xlinker -rpath -Xlinker "$self_config_build" \
  Sources/App/SelfConfigurationAppearance.swift \
  Tests/AssistantSkillsTests/SelfConfigurationFixtures.swift \
  Tests/AssistantSkillsTests/SelfConfigurationTests.swift \
  -o "$self_config_build/checks"
"$self_config_build/checks"
