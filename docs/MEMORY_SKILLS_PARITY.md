# Memory / Skills parity contract

Requested 2026-11-09. This is an implementation and acceptance checklist, **not a
claim of full Mika parity**. Memory and personal skills are in scope; Android
phone-control knowledge, accessibility, screen capture, and native-app operation
remain excluded. A skill never grants additional tool or device authorization.

## Reproducible source baseline

- [Mika 0c172724](https://github.com/wangzan101/Mika/tree/0c172724f3f0c96f7345262588072f6e95db1138)
- [WOOW Android 48dd3b94](https://github.com/WOOWTECH/woowtech_mika_smart_app/tree/48dd3b94b6c025fae4d7a1b25b4b26617e9b7cf6)
- Owner's four Memory / Skills / Pending screenshots supplied in this conversation.

The two revisions have identical `MemoryContext.kt` but differ in `SkillOutcomes.kt`:
Mika counts TokenLimit as a failed task, in addition to GaveUp and StepLimit.
The new iOS rules target the pinned Mika version, not assumed fork equivalence.

Source paths below are relative to the pinned Mika repository. Swift adaptations
carry attribution; the upstream license and NOTICE are retained in this repository.

## Behaviors to preserve

| Area | Required behavior | Source |
|---|---|---|
| Master switch | Off disables runtime retrieval/injection, automatic extraction and memory tools; viewing/editing existing settings is separate | `app/.../settings/MemorySettings.kt` |
| Other switches | Automatic remembering and learning independently persist; default on; learned skills still require approval | same |
| Skills independence | `useMemory` gates memory/profile, not the approved personal-skill catalog; stop a skill using its own switch | `app/.../task/TaskRun.kt:721–728` |
| Memory edits | Facts/preferences active; procedures pending even when manually added; automatic procedure updates require reapproval | `core/.../memory/MemoryStore.kt` |
| Bounds | 200-character entries, eight keywords, 500 entries, 50 in-session undo records; sensitive content rejected | same |
| Retrieval | Pending never injected; Auto gives all active memory if within 4,000 estimated tokens, otherwise ranked/pinned 800-token context | `MemoryContext.kt`, `MemoryIndex.kt` |
| Precedence | Memory is additional user-context, not system authority; current user request overrides old preferences | `MemoryContext.kt` |
| Extraction | Separate post-answer model request; user utterances only; quote validation; at most five changes and ten related records | `MemoryExtractor.kt`, `UserUtterances.kt` |
| Extraction guards | No one-off preference overwrites; explicit forgetting only; no ungrounded specifics; no extraction from observed web pages | same; `app/.../task/RunLearning.kt` |
| Notes | Explain additions/updates/deletions; undo; display from current records rather than retaining deleted plaintext | `MemoryExtractor.kt`, `MemoryRuntime.kt` |
| Import | Pasted full SKILL.md, no model required; validate before pending; explicit approval before use | `core/.../skills/SkillImport.kt` |
| Import metadata | Strip local `source`, `updates`, `learned_from`; assign imported provenance locally; block reserved-name collisions/duplicate pending drafts | same |
| Skill review | Inspect full text; edit; accept as trial; reject; show revisions/diff; changed-source fingerprint prevents stale overwrite | `PersonalSkills.kt`, `app/.../skills/PersonalSkillFiles.kt` |
| Use | Only approved enabled skills may be considered; unavailable tools/scripts cannot become executable through Markdown | `SkillDrafter.kt`, `KnowledgeStore.kt` |
| Outcomes | Keep five; trial becomes active only on Done; trial failure/rejected verification suspends; active suspends on two bad of last three reviewed results or followed/rejected verification | `SkillOutcomes.kt`, `agent/LearnGate.kt` |
| Recovery | Restore chooses trial versus active from prior success evidence, clears stale outcome window; previous revision can be restored | `PersonalSkills.kt`, `ui/MemoryViewModel.kt` |
| Automatic drafts | Need a successful judged task and at least five successful qualifying actions; no replay, skipped takeover, user-finished task, declined confirmation, or duplicate draft after following a personal skill | `SkillDrafter.kt`, `RunLearning.kt` |
| Clear-all | Two confirmations; remove memories/skills/drafts and derived notes; rotate learning key; do not clear model/MCP credentials or claim cookies were cleared | `MemoryViewModel.kt`, `MemoryRuntime.kt` |

`...` abbreviates `com/wangzan101/mika` in app paths and
`kotlin/com/wangzan101/mika/core` in core paths. Consult the actual pinned tree for
complete locations rather than treating shortened table paths as filesystem paths.

## Deliberate capability boundaries / outstanding integration

- Browser website logins must eventually be backed by real WebKit website-data
  records, not screenshot counts or invented records. They are not stored in memory.
- The screenshot's LINE native-app knowledge is outside the agreed iOS scope.
  Website knowledge/revisions and reusable web routes remain browser work, not a
  claim that iOS can operate the LINE app.
- No local shell, downloaded executable scripts, or phone-control tools are exposed.
  Unsupported tool references must be rejected or explicitly unavailable.
- Plain chat completion is not proof that a skill was followed successfully.
  Current model-to-MCP/browser action orchestration and outcome judging are absent;
  automatic skill drafting/promotion cannot be accepted until that evidence exists.
- Model-controlled memory/skill tools, profile consolidation, event-driven automatic
  draft production, complete bundled catalog and website-knowledge lifecycle still
  require integration tests. A lifecycle unit test does not prove these integrations.

## Acceptance matrix

1. Manual fact/preference persists through termination and relaunch.
2. A procedure remains pending and absent from context until approval.
3. Search, edit, pin, delete and undo reflect actual stored state.
4. Master memory switch off sends no memory context and commits no late automatic
   memory changes; turning it off does not destroy saved records. Already-approved
   personal skills remain independently enabled, matching Mika TaskRun.
5. Automatic-remember off still permits explicitly saved memory retrieval.
6. Learned-skill switch off prevents drafting, not deliberate import/review.
7. Real model extraction requires a verbatim user quote; fabricated quotes,
   secrets, one-off changes, unauthorized forgets and malformed JSON are rejected.
8. Model extraction failure leaves the already delivered reply intact.
9. Clearing/editing during an outstanding extraction invalidates its result.
10. Ciphertext contains no plaintext memory; missing key/corruption cannot overwrite
    the old file with an empty state; failed save must not publish success.
11. Valid import appears in Pending and cannot affect model context beforehand.
12. Invalid import preserves the entered Markdown and reports a safe reason.
13. Accept/edit/reject, suspend/resume, delete and previous-version restore persist.
14. Same-name replacement shows a diff and rejects a stale base fingerprint.
15. Export contains no device-local provenance fields.
16. Real model follows an approved text-only skill; pending/disabled skill omitted.
17. HTTP success alone does not promote a trial skill.
18. Verified result and failure-window transitions match the pinned source.
19. Two-stage clear cancellation retains data; confirmed clear rotates the learning
    key while preserving model/MCP settings.
20. Small/large iPhones and current iOS can reach keyboard/editor/confirmation actions.

Evidence and remaining failures are recorded in [VERIFICATION.md](VERIFICATION.md).
Do not substitute fixture-only UI counts for real-service behavior or missing
browser/action-learning acceptance.
