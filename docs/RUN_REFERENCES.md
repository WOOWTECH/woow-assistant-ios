# Run-scoped saved references

Single-site browser research now captures profile, active memory, eligible
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

Local checks execute 33 shared model assertions, 174 actual App assertions in each
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

This increment wires only single-site research. Multi-source research, replayed
routes, document questions, transcription and skill authoring still need their own
run-specific integration and consent boundaries. Search discovery receives no
saved-memory context. A successful check in one runner is not acceptance of the
others or complete Mika parity.
