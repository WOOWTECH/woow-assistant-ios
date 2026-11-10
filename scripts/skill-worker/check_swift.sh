#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
execution_binary="${TMPDIR:-/tmp}/woow-skill-execution-checks"
execution_sources=()
for execution_source in Sources/AssistantSkills/*.swift; do
  case "$execution_source" in *SkillLearningService.swift) ;; *) execution_sources+=("$execution_source");; esac
done
swiftc -D SKILL_EXECUTION_SMOKE -parse-as-library "${execution_sources[@]}" \
  Tests/AssistantSkillsTests/SkillExecutionTests.swift -o "$execution_binary"
"$execution_binary" Sources/AssistantSkills/Resources/MikaBundledSkills.json "$@"
