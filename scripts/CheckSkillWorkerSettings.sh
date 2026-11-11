#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
worker_settings_build=$(mktemp -d "${TMPDIR:-/tmp}/woow-worker-settings.XXXXXX")
trap 'rm -rf "$worker_settings_build"' EXIT
swiftc -parse-as-library -emit-module -emit-library -static -module-name AssistantModels \
  Sources/AssistantModels/*.swift -emit-module-path "$worker_settings_build/AssistantModels.swiftmodule" \
  -o "$worker_settings_build/libAssistantModels.a"
swiftc -parse-as-library -emit-module -emit-library -static -module-name AssistantSkills \
  -I "$worker_settings_build" Sources/AssistantSkills/*.swift \
  -emit-module-path "$worker_settings_build/AssistantSkills.swiftmodule" \
  -o "$worker_settings_build/libAssistantSkills.a"
swiftc -DDEBUG -parse-as-library -I "$worker_settings_build" -L "$worker_settings_build" \
  -lAssistantModels -lAssistantSkills Sources/App/ModelSettings.swift Sources/App/SkillWorkerSettings.swift \
  Sources/App/AppLanguage.swift Sources/App/AppText.swift Sources/App/AppLocalizer.swift Sources/App/AppModelSettingsText.swift \
  scripts/SkillWorkerSettingsChecks.swift -o "$worker_settings_build/checks"
"$worker_settings_build/checks"
