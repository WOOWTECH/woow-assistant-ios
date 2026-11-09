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
  Website knowledge/revisions and observed read-only web routes now have a native
  implementation, with fixture App flows passing on three simulators. Live-service
  acceptance is tracked separately. It does not operate LINE.
- No local shell, downloaded executable scripts, or phone-control tools are exposed.
  Unsupported tool references must be rejected or explicitly unavailable.
- Plain chat completion is not proof that a skill was followed successfully.
  The current browser research runner now supplies actual read/navigation evidence
  to an independent outcome judge; model-to-MCP orchestration remains absent.
  Drafting/promotion must be accepted with separate core, App UI and live evidence.
- Model-controlled memory/skill tools, profile consolidation and complete bundled
  catalog remain unimplemented. Event-driven browser draft production and website
  lifecycle have passing fixture App tests on all three simulators. Real-model
  multi-page learning through approval/relaunch also passed separately (evidence
  below); lifecycle unit results are not substituted for that integration.

The 2026-11-10 browser increment deliberately restricts URLs to public HTTPS without
queries/fragments, same-origin research links, ephemeral website data and read-only
actions. It is not full Mika browser parity. Outcome assessment adds exact observation
citations, and deduplicates executed actions before the five-action drafting gate.
Website quotes are references, not user memory; approval remains separate. Tests
must distinguish real models over synthetic traces from actual browser execution.

### Website adaptation and review flow

Mika's `AppKnowledgeLearning.kt` drafts facts for `Surface.Android` only and uses
Draft → Trial → Verified/Archived stages. Those native-app facts remain excluded
from this iOS scope. The website records added here are a source-grounded adaptation,
not a claim that this Android lifecycle has been copied unchanged: website lessons
currently have Pending/Approved states plus revision history. Personal **skills**
retain their separate trial/outcome lifecycle.

The implemented website flow can be reviewed from Browser → open a public page →
Research. A single-page answer may be judged done without producing a skill.
Five distinct successful qualifying navigation actions are required before a new
skill is eligible for drafting; repeated reads and text searches cannot pad that
count. The model may still decide there is no reusable draft. An accepted draft
appears in Memory → Pending, with its full Markdown available before approval.
Approval creates a trial skill, not a verified one.

Memory → Website knowledge and routes shows the separately saved page quote,
source URL and route. Pending website lessons are excluded from saved context.
Approved context is scoped to the exact scheme/host/port. A route is derived from
actual navigation/inspection, and requires an explicit replay action. Replay reads
the page again, checks each URL/quote, then answers and judges the original task;
matching page text alone is insufficient for success. Two consecutive mismatches
at the same step disable that route. These are read-only web routes, with no form
submission, credential input or native-app selectors.

Changing model settings or learning data cancels outstanding browser work and
invalidates late results. This cannot retract requests already sent to a service.
App restart preserves approved/pending learning records and routes, but not the
ephemeral browser's cookies or session. UI fixtures exercise the real WebKit/store
with local HTML; they do not prove live service behavior.

## Real browser learning evidence — 2026-11-10

The [live simulator run](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42711916423)
passed all six App UI cases with zero skips, alongside seven native model calls.
The actual IANA five-page case completed in 157.434 seconds: five full-URL answer
citations, exactly six real reads (initial inspect plus five unique navigations),
independent done judgment, one saved pending skill, fulltext review, explicit UI
approval into trial, and byte-identical Markdown/provenance after termination and
relaunch. A single-page explanation was independently judged done without inventing
a skill. Automatic memory/relaunch, disabled-memory recall, cancellation, transport
failure and multi-turn context also passed. The latest test revision `fbe4669` only
changes navigation readiness; App source is unchanged from `2654965`.

This evidence validates the implemented read-only website-learning flow on a
simulator with a real model and real website. It does not establish full Mika browser
or bundled-catalog parity, physical-device behavior, or native-app knowledge/control.

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
21. Website research records actual WebKit reads/navigation; fabricated, arbitrary
    script/URL commands and repeated actions cannot manufacture learning eligibility.
22. Successful judged research can create a pending skill, with unchanged reviewed
    Markdown surviving approval and App relaunch; approval alone leaves it in trial.
23. One-page real-network research can be judged done without inventing five steps
    or a new skill. Exact success status is required, not the substring “completed”.
24. Website facts preserve their URL, capture time and source quote independently
    of personal memory. Manual saving works without model credentials.
25. Website approval/revisions and route state persist; pending or other-origin
    website records are excluded from context.
26. Replaying a persisted route after App relaunch opens the real browser, rereads
    each step and judges the answer before recording success; replay produces no
    duplicate skill. Divergence disables only after the specified failure window.
27. Removing model settings during research cancels work, preserves the goal and
    leaves no late answer, memory, skill, website fact or route from that run.
28. Interrupted assessment, invalid verdicts, stale fingerprints and conflicting
    duplicate skill references cannot partially publish outcome/draft state.

Evidence and remaining failures are recorded in [VERIFICATION.md](VERIFICATION.md).
Do not substitute fixture-only UI counts for real-service behavior or missing
browser/action-learning acceptance.
