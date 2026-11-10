# Run-scoped saved references

Single-site and multi-source browser research now capture profile, active memory, eligible
approved personal skills and website knowledge before starting. The capture uses
the actual encrypted LearningStore and existing retrieval/capability checks.
Capture itself does not write storage, increment usage, invoke a model or navigate.

The combined envelope is at most 6000 Swift Characters and 24000 UTF-8 bytes.
Complete JSON entries are included in retrieval order, interleaved across kinds;
entries that do not fit are omitted whole. The envelope is a user-role data message
before the current goal, never a system instruction, citation or tool grant.
Memory/profile obey the memory master switch. Approved skills keep their own
enable and capability checks independently. Website references keep their existing
site-specific selection and settings.

Each run owns an immutable reference value and a revocation latch. Ordinary edits
affect the next capture. Deleting/disabling captured references, turning off memory,
clearing data, reloading or losing storage availability revokes the current run.
Profile replacement followed by deleting an unrelated entry does not falsely
revoke the captured old profile. Unrelated learning generations do not act as the
run's cancellation token. Browser tab/scene changes still cancel existing work.

The actual BrowserSession checks cancellation before navigation; the runner also
checks before and after awaited model/browser work. A deterministic regression
with an already-cancelled, valid observed link previously started one navigation
and claimed the page. After correction it starts none, keeps the URL unchanged and
does not claim automation. This experiment does not establish every possible
in-flight actor ordering.

Local checks execute 33 shared model assertions at the original reference-core revision, 378 actual App assertions in each
of Debug and Release, 238 existing research assertions and existing ChatSession
regressions (573 Debug / 492 Release). App checks include real macOS WebKit with
synthetic local HTML, actual temporary encrypted storage, live object lifecycles
and controlled model transports. They make no external model request and are not
iOS UI or physical-device acceptance. Ten hosted App methods and four model
methods are included for native execution.

- [Shared core checks and hashes](evidence/run-reference-core-local.json)
- [Actual App checks and hashes](evidence/learning-run-context-app-local.json)
- [Earlier unchanged ChatSession regressions and captured UI source](evidence/learning-run-context-app-handoff.json)
- [Reproduced before/after regressions](evidence/learning-run-reference-regressions.json)

Replayed routes, document questions, transcription and skill authoring still need their own
run-specific integration and consent boundaries. Search discovery receives no
saved-memory context. A successful check in one runner is not acceptance of the
others or complete Mika parity.


Multi-source research captures website knowledge only for the two or three
explicitly approved roots, deduplicated by origin. Those sites share the existing
five website rows and the same combined reference budget; saved URLs never grant
navigation. References remain separate from the actual receipt ledger, and only
observed source text can support citations. Settings changes and deleting a captured
website revoke the run, including while a model response is pending.

The model message array now has an explicit combined ceiling of 120000 Swift
Characters / 480000 serialized UTF-8 bytes, derived from the existing fifteen
8000-character page allowance. This is a new, stricter total bound because it also
charges system instructions, the goal and JSON metadata. Complete observations
are retained; the entire reference block is omitted if space is insufficient.
Required observations exceeding the ceiling stop before another model request
with a fixed error while preserving actual read receipts. The existing twelve-call
and 180-second limits are unchanged.

Local multi-source checks pass 36 new core, 74 existing core, and 197 Debug / 31
Release App assertions. Debug uses two actual isolated WebKit stores and controlled
model responses; Release checks capture, preflight and cancellation without fixture
page reads. Single-site regressions still pass 238 core, 378/378 App and 573/492
Chat assertions. Four new core and five hosted App methods await native iOS checks.
[Multi-source evidence](evidence/multi-source-reference-local.json),
[single-site regression evidence](evidence/multi-source-single-regression-local.json).


A reproduced replacement/deletion defect is corrected: when a captured profile row
A is replaced by A′, deleting A′ must also revoke the run still holding A. A small
in-memory lineage set tracks the current descendant only after successful manual
or reviewed-tool persistence. Ordinary replacement keeps the captured text frozen;
deleting unrelated B leaves the run valid. Chained/no-op replacement, stale edits
and failed writes are covered. Domain IDs and encrypted file schema are unchanged.
Eleven multi-source cancellation paths now await the actual captured run task's
completion before asserting zero new navigation and no late result, rather than
assuming a model counter or a few task yields prove completion.
[Reproduced defect, correction and completion evidence](evidence/profile-lineage-completion-local.json).

The final reports above come from an isolated `ae381fc` checkout plus the frozen
reference changes. The later independent PDF-pair fixture update is validated
separately. The combined `1abc6d7` tree subsequently passed 286/286 native/hosted
methods on iOS 26.2, including all 19 reference-related methods; the separate
portable execution passed 207/207. See [native evidence](evidence/native-current-1abc6d7.json).


The actual-model follow-up passes three cases on macOS with real public WebKit
observations and synthetic saved references: a saved formatting preference, a
contrary current request, and separation of references from citation evidence.
Nine cited ranges match the observed sources exactly. The separately labeled
forged-citation replay uses a synthetic command over those observations with zero
network requests. The first unsuccessful attempt, HTTP-400 diagnostic and corrected
model-selection run are preserved in [the evidence chain](evidence/multi-source-references-live-fixture.json).
This does not exercise user-vault capture or native iOS UI. The optional checker
requires explicit `--live`; compiling or running its seven report/budget tests
makes no model request.
