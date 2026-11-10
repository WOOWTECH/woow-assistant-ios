# Transcript saved references

The actual transcript model path now captures the host's `LearningStore` at explicit
Start, after source approval and destination confirmation. The Files entry in Memory,
the bundled catalog entry, and the approved browser-text entry all pass the same
host store. `TranscriptView(learning:modelAccess:modelChanges:approvedSource:)` and
`TranscriptSession(learning:)` require explicit injection; neither falls back to
production defaults or Keychain. The offline App checks use a unique temporary
encrypted vault and in-memory key/credential stores. `LiveTranscriptSmoke` constructs
only the core runtime and continues to use its default empty reference context.

The reference snapshot uses the existing `LearningRunSnapshot` contract. Memory and
profile follow the memory switch; reviewed, enabled personal skills have independent
capability checks. The only transcript capability is source-bound `read_file`.
Retrieval uses the user's selected format, never text, filenames, or model output
from the approved source as a new user request. The one immutable reference block
is user-role data placed before the current format/source request. Empty references
preserve the original message shape. The existing combined 6000-character / 24000-byte
reference budget and 256-KiB model-history ceiling both apply.

This follows the pinned Mika intent at
`0c172724f3f0c96f7345262588072f6e95db1138`, inspected in local source:
[TaskRun.kt](https://github.com/wangzan101/Mika/blob/0c172724f3f0c96f7345262588072f6e95db1138/app/src/main/java/com/wangzan101/mika/task/TaskRun.kt#L717)
gates memory/profile while retaining the personal skill catalog;
[AgentLoop.kt](https://github.com/wangzan101/Mika/blob/0c172724f3f0c96f7345262588072f6e95db1138/core/src/main/kotlin/com/wangzan101/mika/core/agent/AgentLoop.kt#L372)
builds saved context before the current task; the pinned
[content-transcribe skill](https://github.com/wangzan101/Mika/blob/0c172724f3f0c96f7345262588072f6e95db1138/core/src/main/resources/skills/content-transcribe/SKILL.md)
requires full source reading and the user's requested format. iOS preserves its
existing approval, exact-quote, timestamp, quota and cancellation boundaries.

Saved references never satisfy source coverage, citations, tools or file paths.
The consent text explicitly discloses reference transmission and has the stable
identifier `transcript.referenceNotice`. Model history and outputs are not written
back to memory or skills. Normal edits remain frozen for the current run; deletion,
skill disable, memory switch off, replacement-lineage deletion, clear, reload and
storage unavailability revoke it. Revocation stops the actual task, retains the
approved source, clears destination consent, and rejects late delivery. A completed
run releases its reference latch; later deletion does not erase the delivered result.

An observed cancellation defect was also corrected. The previous structured task
group waited for a cancellation-insensitive model child even after the UI stopped.
`TranscriptModelRace` now arbitrates reply, cancellation and deadline exactly once.
The actual run task returns while that synthetic model remains held; a late transport
reply cannot read source, call the model again or update a newer run. A transport
that ignores cancellation may retain its already-sent request until it returns;
revocation does not retract information previously sent. The cumulative model wait
budget and single format-correction allowance remain unchanged.

Validation uses `python3 scripts/check_transcript_references_app.py`. It captures
working-tree source bytes, builds real modules and App sources without substitutions,
runs shared test bodies in Debug and Release, and compile-checks the real HTTP live
entry point without executing it. Every evidence report distinguishes macOS execution,
iOS syntax parsing and unavailable native acceptance. CLT on this host has no XCTest
module; the checker records that limitation without a replacement stub. Source drift
is retained as `SOURCE_CHANGED` and never automatically rerun solely for drift.

Coverage includes consent/no request before Start; switches and capability exclusions;
immutable user-role snapshots across correction; encrypted storage unchanged by runs;
source-only citations; reference bytes actually stopping a request at the combined
history ceiling; captured deletion/disable/clear/reload/unavailable/settings/cancel
while either the first model command or final model answer is held; actual task join
before release; late old reply after a distinct new-source delivery; cancellation and
deadline with a deliberately noncooperative client. Existing transcript suites also
cover the five formats, file approvals/bounds, HTTP transport cancellation, source
grounding and correction quotas.

Native and local registration:

- `Tests/AssistantSkillsTests/TranscriptReferenceTests.swift` supplies three native
  methods via the existing directory source entry: `testImmutableUserRoleReferenceMessages`,
  `testReferencesCannotSupplyEvidenceToolsOrExtraCalls`, and
  `testActualTaskFinishesBeforeCancellationInsensitiveReply`.
- `scripts/CheckTranscriptReferencesApp.swift` is registered in `AssistantSkillsTests`, alongside
  `CheckDocumentQueryApp.swift`, with its existing host/module dependencies. Its class
  `TranscriptReferenceAppIntegrationTests` has five methods: `testConsentCaptureAndCompletion`,
  `testSwitchesAndCapabilityBounds`, `testFrozenEditsAndDestination`,
  `testRevocationJoinsHeldActualTask`, and `testOldRunCannotReplaceNewDelivery`.
- Both classes are selected by the focused transcript scope and full native suite.
  They share the offline bodies; there is no second mock implementation.
- `scripts/check_transcript.sh` now invokes the actual-source checker. Its former
  `ModelAccess`-only stub is removed; all core suites, actual App checks and live
  entry-point compilation remain covered.

Remaining independent scope: personal skill authoring still validates browser-only
capabilities; this change does not expand worker or generic tool grants. Automatic
learning/outcome recording and task notifications for standalone transcript sessions
remain separate work. Notification routing would first need a root-retained task
owner so opening a route cannot destroy or cancel its own pending result. There is
no new deployed worker endpoint, signing identity or device configuration in this
increment. Local passes do not establish live-model behavior, native UI acceptance,
audio transcription, semantic truth of a summary, or complete Mika parity.

Final local snapshot: 238 App assertions and 17 core suites pass in each of Debug
and Release. Both real-HTTP live entry points compile without execution. All 109
captured sources were unchanged throughout this run. The existing UI-fixture
preparation command also passes its Debug gates and Release exclusion checks;
those are portable fixture checks, not native UI tests. No personal Keychain or
external model service was used. Native XCTest/SwiftUI acceptance remains pending.

Evidence: [final local results, source hashes and owner manifest](evidence/transcript-reference-local.json);
[original failure, intermediate snapshot and missing-XCTest diagnostic](evidence/transcript-reference-cancellation-regression.json).
