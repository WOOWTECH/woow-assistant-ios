#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
transcript_ui_dir="$(mktemp -d "${TMPDIR:-/tmp}/woow-transcript-ui-checks.XXXXXX")"
printf 'Transcript UI preparation checks: %s\n' "$transcript_ui_dir"
swiftc -swift-version 5 -D DEBUG -D TRANSCRIPT_UI_FIXTURE_CHECKS -parse-as-library \
  Sources/App/TranscriptUITestSupport.swift Tests/WoowAssistantUITests/TranscriptUITests.swift \
  -o "$transcript_ui_dir/debug-fixture-checks"
"$transcript_ui_dir/debug-fixture-checks" | tee "$transcript_ui_dir/debug-results.log"
swiftc -swift-version 5 -D TRANSCRIPT_UI_FIXTURE_CHECKS -parse-as-library \
  Sources/App/TranscriptUITestSupport.swift Tests/WoowAssistantUITests/TranscriptUITests.swift \
  -o "$transcript_ui_dir/release-fixture-checks"
"$transcript_ui_dir/release-fixture-checks" | tee "$transcript_ui_dir/release-results.log"
swiftc -frontend -parse Sources/App/TranscriptSession.swift Sources/App/TranscriptView.swift \
  Tests/WoowAssistantUITests/TranscriptUITests.swift Tests/WoowAssistantUITests/LiveTranscriptUITests.swift
