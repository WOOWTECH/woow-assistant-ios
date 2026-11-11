# Verification — 2026-11-11

## Chat PDF Files picker driver candidate awaits native retest

The `61c8e3e` three-method `documents-chat` UI shard completed **1 pass / 2
failures** on [SE/iOS 18.5](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42969099406).
The [current/iOS 26.2 run](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42969112726)
timed out with no complete three-method summary. The SE fixture showed a
visible native Files location row that the driver did not select; current
left Files open after tapping a thumbnail image rather than the exact unique
file cell. The driver now searches bounded visible location rows and taps the
verified native cell once. Original approval, cancellation, archive, citation
and relaunch assertions remain. This is a candidate, not a pass, until native
reruns finish. [Original method-level evidence](evidence/chat-pdf-picker-reruns-61c8e3e.json).

## SE full native core completed at `43ba9d0`

[Run 42971185488](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42971185488)
passed **345/345 seven-target iOS XCTest core methods** on a fresh iPhone SE
(3rd generation) / iOS 18.5 simulator, plus **217/217 portable macOS core
methods**, with zero failed or skipped. The 819-member artifact ZIP matched
GitHub's SHA-256 digest and passed CRC checks. Each method started and passed
exactly once, and the native completion gate matched the summary. The method
sets match the current/iOS 26.2 run at the same source revision. UI shards,
live services, physical iPhone and the pending exact17 rerun remain separate.
[Method lists and artifact evidence](evidence/native-se-full-43ba9d0.json).

## Current full native core completed at `43ba9d0`

[Run 42971179669](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42971179669)
passed **345/345 seven-target iOS XCTest core methods** on a fresh iPhone 17 /
iOS 26.2 simulator, plus **217/217 portable macOS core methods**, all with
zero failed or skipped. The complete 819-member artifact ZIP matched GitHub's
SHA-256 digest and passed member CRC checks. Each of the 345 iOS methods and
217 portable methods started and passed exactly once; native completion
verification matched the 345-method summary. This covers no UI shard, live
service or physical iPhone. New [SE](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42971185488)
and [exact17](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42971191200)
full-core reruns remain independent. [Method lists and artifact evidence](evidence/native-current-full-43ba9d0.json).

## Staged two-PDF FileProvider branch remains isolated at 2/3

The `d8b568e` isolated branch creates PDF B only after the first genuine
native Files picker callback for PDF A. Its focused two-file assembly method
passed **1/1, zero skipped** on [SE/iOS 18.5](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42966422108)
and [exact17](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42966427095),
but [current iOS 26.2](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42966416710)
failed **0/1** at the 300-second method limit after export Cancel, before the
final retained-result check. All three runs recorded two native picker
callbacks; current completed the page-order and assembly checks before its
timeout. Full artifact ZIP digests and CRCs were verified. This does not
establish the earlier FileProvider `-1005` root cause or a three-platform fix.
The branch stays outside main while its current timeout is investigated.
[Three-platform branch evidence](evidence/pdf-pair-d8b568e-staged-three-platforms.json).

## Exact17 skills UI passed; profile UI stopped at keyboard setup

At `e3eda78`, [exact17 skills run 42967066402](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42967066402)
passed its selected `ui-skills` shard **10/10, zero skipped**. Each expected
method completed once; the full 69-member ZIP matched its GitHub SHA-256 and
passed all CRC checks. This covers the selected skills, authoring and
transcript UI cases, not the original Mika tool runtime or live model service.
[Method and artifact evidence](evidence/ui-skills-e3eda78-exact17.json).

The same source's [exact17 profile run 42967061906](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42967061906)
finished **0/9 passed, nine failed, zero skipped**. All five profile methods
and four profile-tool methods stopped at their setup keyboard switch; the
tests queried `Next keyboard`, while 18 native AX snapshots exposed the
visible button label `下一個鍵盤`. No profile data or approval assertion was
reached. Both test drivers now accept the two observed native labels and
retain the original data, review and relaunch assertions. This candidate
needs a new exact17 native run. [Failure, AX and artifact evidence](evidence/ui-profile-e3eda78-exact17.json).

## New live-model gate preserves the provider failure

At `0a99e5f`, [SE/iOS 18.5 run 42969482818](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42969482818)
built the App successfully, then its native model request stopped with the
fixed `rate_limited` category. The five-format transcript and App UI steps
were correctly **skipped**, while private runner cleanup and simulator
deletion succeeded. This run supplies no successful real model conversation
or UI acceptance. A scan of its public log found zero occurrences of the
configured service host family, service domain, common API-key pattern or
GitHub token pattern; this is a bounded log check, not a claim about all
possible secret transformations. [Safe step and log-hash evidence](evidence/live-model-0a99e5f-gated-rate-limit.json).

## Language UI: current and SE pass, exact17 one timeout

At `ae7a1e2`, native `ui-language` passed **5/5, zero skipped** on
[iOS 26.2](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42964296156)
and [SE/iOS 18.5](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42964303127).
The [exact17 run](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42964308326)
passed **4/5, zero skipped**. Its English Browser/Library/Search/Catalog case
reached the `catalog.empty` check at its 240-second case limit; the final chat
draft assertion was not reached. The same run passed the English
MCP/Notifications case, including native back navigation and draft readback.
No English text assertion failed before the timeout. AX logs show the
`settings.language` control is a Button on all three runtimes; using that role
directly removes a costly global Any query in the test driver. The full ZIP
digests and member CRCs were checked for all three runs. An exact17 native
rerun is required before the changed driver or complete language shard can be
accepted. [Three-platform method and artifact evidence](evidence/ui-language-ae7a1e2-three-platforms.json).

## Exact17 memory UI preflight interrupted by Simulator inventory

[Run 42967057485](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42967057485)
failed while listing installed simulator runtimes after the fixed 120-second
bound. It never started any of the eight selected `ui-memory` methods, so no
memory behavior can be judged from that run. The earlier unstarted rerun was
cancelled; [replacement exact17 run 42974321694](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42974321694)
is queued with the bounded inventory retry. [Fixed-category preflight and
artifact evidence](evidence/ui-memory-e3eda78-exact17-runtime-timeout.json).

After this second observed runtime inventory timeout, `release_ios17.py` now
retries that one `simctl list runtimes --json` call **once only after a timeout**.
Each attempt remains bounded at 120 seconds; launch and nonzero-exit failures
still stop immediately, the requested iOS version is still matched exactly,
and exhausted retries keep a failed run with fixed category and attempt count.
The local release-script tests passed **43/43**, including real child timeouts,
recovery after one timeout and private-output checks; another 59/59 exact17
tooling tests passed. Native hosted validation remains pending.

## Exact iOS 17 saved-PDF chat UI completed at `23b4e6a`

[Run 42965803863](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42965803863)
passed the focused `documents-chat` shard **3/3, zero failed or skipped** on
iPhone 15 / iOS 17.0.1. Its methods each ran once and exercised PDF citations,
page extraction, archive reopen and deletion/relaunch. Expanded AX snapshots
show separate identifiers for the saved PDF row, citation text and pages
button, resolving the earlier nested-disclosure collision on this runtime.
The 59-member full ZIP passed SHA-256 and all-member CRC verification. This
result does not cover other UI shards or a live model service.
[Method, AX and artifact evidence](evidence/documents-chat-23b4e6a-exact17.json).

## Exact17 archive UI failed at native keyboard selection

At `e3eda78`, [exact17 run 42967052289](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42967052289)
executed four `ui-archive` methods: **0 passed, 4 failed, zero skipped**.
All four stopped during setup at the same `ready()` assertion, before any
archive behavior. The test sought the English `Next keyboard` button, while
the native iOS 17 AX snapshots show its visible label as `下一個鍵盤`. The
test selector now accepts both observed labels and still requires an actual
hittable native switch, exact typed text, and the original archive assertions.
This is an unvalidated candidate until a new native run completes.
[Full ZIP digest, counts and failure evidence](evidence/ui-archive-e3eda78-exact17-keyboard.json).

## Live public source discovery isolated from model quota

At `fe66ab2`, the exact17 live-model [run 42961323643](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42961323643)
failed both `LiveSourceDiscoveryUITests` before a public-search tap: iOS 17
exposed the vertical native input as a `TextView`, and the test stopped at its
keyboard query. The SE [run 42961335239](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42961335239)
passed both source-discovery methods and completed real public search and
selection of two different origins. Both runs independently classified their
model transport as HTTP 429 `rate_limited`; that does not explain exact17's
pre-search UI failure. [Sanitized method-level diagnosis](evidence/live-source-discovery-fe66ab2-diagnosis.json).

The focused test now handles only the known native keyboard introduction,
then still requires `typeText`, an exact input value, the visible Done button,
the public search and the existing source-selection assertions. The
`source-discovery` workflow scope skips unrelated model probes, so a provider
429 cannot prevent this independent browser acceptance test. Other live
scopes keep the successful model-transport prerequisite. This candidate
requires a new native exact17 run; it has not passed yet.

## Three-platform browser workspace interface completed at `fe66ab2`

The native `ui-workspace` shard passed **9/9, zero failed or skipped** on
[current iOS 26.2](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42961063289),
[SE/iOS 18.5](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42961079617),
and [exact iOS 17.0.1](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42961096341):
**27/27 selected method executions**. The nine methods cover native form login,
cookie sharing and clearing, tabs, bookmarks, history, custom search, manual
GET site mode, JavaScript dialog and page find. Every method started and passed
once; complete artifact ZIP digests and all-member CRCs matched. The exact17
release report marks the selected tests successful, while its full-acceptance
flag remains false by the intentionally narrow scope. These cases use local
test pages; they do not accept external account login, all browser features,
or complete Mika parity. [Aggregate run and method evidence](evidence/ui-workspace-fe66ab2-three-platforms.json),
[current](evidence/ui-workspace-fe66ab2-ios26-current.json),
[SE](evidence/ui-workspace-fe66ab2-ios18-compact.json),
[exact17](evidence/ui-workspace-fe66ab2-exact17.json).

## Current startup streaming UI rerun pending

At `a03eac0`, [current run 42956288760](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42956288760)
passed **14/15** selected startup UI cases, zero skipped. The remaining
`ChatStreamingUITests/testPartialBecomesCompletedReplyAndDurableArchive` stopped
while entering the settings model field: its visible field received a native
tap, but the keyboard did not appear. The completed-stream and saved-archive
assertions were not reached. SE [run 42956303279](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42956303279)
passed **15/15** on that source. The candidate changes only the test's focus
transition between URL and model fields; it retains native keyboard, exact
field value, streaming and archive assertions. A current native rerun is
required before this case can be accepted.

## Three-platform MCP interface completed at `fe66ab2`

The native `ui-mcp` shard passed **8/8, zero skipped** separately on
[current iOS 26.2](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42961017274),
[SE/iOS 18.5](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42961031203),
and [exact iOS 17.0.1](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42961045935):
**24/24 selected method executions**. Each full artifact ZIP passed SHA-256 and
all-member CRC checks; every selected source method completed exactly once.
The learning method actually clicked remote and local approvals, closed the
result sheet, undid the stored change, then relaunched without reset and
verified empty memory/pending state. The former current setup-navigation
failure did not recur. These are **synthetic MCP fixture** UI cases; real HA
model conversations failed separately at `fe66ab2` and are not accepted by
this result. [Aggregate method/source/AX evidence](evidence/ui-mcp-fe66ab2-three-platforms.json),
[exact17](evidence/ui-mcp-fe66ab2-exact17.json),
[current](evidence/ui-mcp-fe66ab2-ios26-current.json),
[SE](evidence/ui-mcp-fe66ab2-ios18-compact.json).

## Current product source compiles for iPhoneOS

At `d03dbde`, [run 42970132111](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42970132111)
completed an **unsigned Release iPhoneOS build** with Xcode 26.2, minimum iOS
17.0 and nine verified binaries. This source includes the manual website media
delegate/purpose strings and saved-PDF accessibility product corrections. The
full two-member artifact ZIP passed SHA-256 and CRC checks; the build log has
one `BUILD SUCCEEDED`, no build failure and no compiler error line. It is not
signed or installable. The new release gate verified the nonempty camera and
microphone purpose strings in the built App package.
[Artifact evidence](evidence/unsigned-device-d03dbde.json).

## Current simulator selected core with website media source

At `1fb3aea`, [run 42962749795](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42962749795)
passed 217/217 portable macOS core methods and **152/152 selected iPhone 17 /
iOS 26.2 XCTest methods**, zero failures and zero skips. The iOS selection was
only `AssistantMemoryTests`, `AssistantPersistenceTests`, and
`AssistantSkillsTests`; it was **not** the seven-target full native scope.
The 374-member full artifact ZIP passed SHA-256 and CRC checks; both logs have
unique matching starts/passes, and the iOS summary matches 152/152.
The App build contains the website media delegate/purpose strings, but this
does not exercise an OS camera/microphone prompt. The separate full-scope
rechecks are queued for [current](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42971179669),
[SE](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42971185488),
and [exact iOS 17](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42971191200).
[Method and artifact evidence](evidence/native-current-selected-core-1fb3aea.json).

## Exact iOS 17 live-model suite blocked at model service

At `fe66ab2`, [run 42961323643](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42961323643)
finished **failed**. Its native iOS Simulator JSON/SSE smoke stopped before a
successful reply with the fixed category `rate_limited`. A separate real HTTP
probe attempted all five fixed-text transcript formats: **0/5 passed**, each
with one model call, zero responses and the fixed `modelFailed` code. The App
UI started 18 methods: **2 passed, 16 failed, zero skipped**. The two passes
cover cancellation and an intentionally invalid transport; they do not accept
successful model replies. The transcript and UI logs do not prove that every
failure was a 429, nor whether concurrent jobs caused the provider limit.
No private configuration, model output or raw log was published in the
[sanitized evidence](evidence/live-model-exact17-fe66ab2-first-failure.json).

Following this observed limit, the live-model workflow now gates its fixed-text
probe and model-dependent UI suite on the bounded native JSON/SSE probe. The
live-HA workflow first performs its existing read-only HA probe, then the same
bounded model probe before building/running model-dependent UI. A failed probe
still fails its workflow, and no conversation case is marked passed. Both
workflow edits passed local `actionlint`; the live-HA prelaunch checks passed
7/7. The new gates have not yet run in GitHub Actions.

Four additional latest-source, non-Live iOS 17 UI shards are queued:
[archive](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42967052289),
[memory](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42967057485),
[profile](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42967061906),
and [skills](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42967066402).
Their dispatch does not constitute a pass.

The companion SE/iOS 18.5 real-model run at `fe66ab2`,
[42961335239](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42961335239),
also failed its native probe with fixed `rate_limited`, then completed **0/5**
fixed-text formats (one call and zero replies each). Its UI started 18 methods:
**3 passed, 15 failed, zero skipped**. The passes were invalid-transport draft
retention and two public search behaviors; they do not accept a successful
model response. This matches the iOS 17 service-entry failure, while individual
UI assertion causes remain separate. [Sanitized SE evidence](evidence/live-model-se-fe66ab2-first-failure.json).
One new-source, bounded [SE full live-model rerun](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42969482818)
is queued alone; its gate will stop dependent steps if the native probe fails.
The earlier pending [42968311920](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42968311920)
was cancelled before starting and replaced so the new run also uses masked
model-service settings.

A bounded review of those two public failed-step logs found the model service
host printed three times in each, because GitHub Actions configuration
variables are not masked by default; it found no credential-shaped model or
GitHub token in either downloaded log. The existing service URL and model ID
were copied to repository Actions secrets without printing their values, and
future live-model/live-HA workflows now read those secrets. The older logs are
unchanged. A subsequent run must confirm actual redaction; GitHub notes that
secret masking is not guaranteed for transformed values.
[GitHub variables](https://docs.github.com/en/actions/concepts/workflows-and-actions/variables),
[GitHub secrets](https://docs.github.com/en/actions/concepts/security/secrets).

## Staged dual-PDF FileProvider experiment in isolated branch

Current and SE logs correlate missed native picker callbacks with FileProvider
`-1005` while the synthetic PDF inode/hash remain unchanged in later checks.
Apple defines `noSuchItem` as a specified item not existing, but these logs do
not prove the FileProvider root cause. The isolated
[`d8b568e` branch](https://github.com/WOOWTECH/woow-assistant-ios/tree/test/pdf-pair-staged-fileprovider)
tests one new hypothesis: show only PDF A before the first Files picker, then
create PDF B only after A's genuine native selection callback. It preserves two
Files selections, separate grants, A2/B1/A1 page order and cancelled-export
assertions. Local Debug/Release checks and workflow lint passed. Three focused
native runs are pending: [current](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42966416710),
[SE](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42966422108),
[exact iOS 17](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42966427095).
The candidate is **not in main** and is not yet accepted as a fix.
[Patch scope and local checks](evidence/pdf-pair-staged-branch-d8b568e.json),
[Apple error definition](https://developer.apple.com/documentation/fileprovider/nsfileprovidererror/code/nosuchitem).

## Unsigned iPhoneOS build after MCP results correction

At `fe66ab2`, [run 42961148082](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42961148082)
completed an **unsigned iPhoneOS build** with Xcode 26.2, minimum iOS 17.0
and nine verified binaries. The full two-member artifact ZIP passed SHA-256
and CRC checks; its build log has one `BUILD SUCCEEDED` and no build error.
It is not signed or installable. This source predates the later website media
permissions and archived PDF accessibility corrections. A newer unsigned
build [42966148674](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42966148674)
is queued. [Artifact and report evidence](evidence/unsigned-device-fe66ab2.json).

## Live HA MCP on SE/iOS 18.5 and exact iOS 17: model stage fails

At `fe66ab2`, [run 42961307238](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42961307238)
completed the private read-only HA protocol step and native App build, then
failed the real MCP UI scope: **1/4 passed, 3/4 failed, zero skipped**. Discovery,
disconnect and reconnect passed. The three conversation methods stopped before
any remote approval; two fixed diagnostics explicitly reported
`modelRateLimited` after the first model call, and the third recorded an error
at its first remote-proposal stage without a fixed failure category. Concurrent
live jobs may have contributed to rate limiting, but the run does not prove
that cause. No private endpoint, credential, model reply or tool result is
published. This is **not** a successful real model/MCP conversation acceptance;
subsequent runs must be assessed separately.
The exact iOS 17.0.1 run
[42961293619](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42961293619)
showed the **same 1/4 UI result**, the same three failing methods, and the
same two explicit first-call `modelRateLimited` diagnostics. Its read-only HA
step and App build also passed; its UI result remains failed. The two platform
results do not establish whether shared model capacity or another provider
policy caused the rate limit.
[SE sanitized evidence](evidence/live-ha-se-fe66-first-failure.json),
[exact iOS 17 sanitized evidence](evidence/live-ha-exact17-fe66-first-failure.json).

## Exact iOS 17 archived PDF content loses child accessibility IDs

At `0170d3c`, exact iOS 17.0.1 documents-chat completed **2/3 methods**,
zero skips. The earlier outer disclosure selector now found and opened the
saved PDF: the bounded AX snapshot grew from 32 to 39 nodes. The new first
failure was the saved citation query. Citation and nested page nodes inherited
the outer `archive.turn.0.pdf` accessibility identifier, so the expected
`archive.turn.0.pdf.citation.0` did not appear. Citation, page, reopen and delete
assertions did not run. This points to the App's outer `DisclosureGroup`
identifier propagation, not just the test lookup. At `23b4e6a`, the archived
view now uses separate identified buttons for the outer PDF and inner pages,
with citation/page text as sibling accessibility nodes. The test retains its
later business assertions and checks each button's expanded state. The focused
native rerun [42965803863](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42965803863)
is pending; no pass is claimed. The failed 148,776,218-byte ZIP passed
SHA-256 and all-member CRC checks.
[Method, source and AX evidence](evidence/chat-pdf-exact17-017-citation-collision.json).
[Scoped candidate and local checks](evidence/chat-pdf-ax-siblings-23b4e6a-local.json).

## Language UI rerun: 4/5 on each simulator

At `dfd6eff`, current iOS 26.2, SE/iOS 18.5 and exact iOS 17.0.1 each
completed **4/5 ui-language methods**, zero skips. The two newly added English
screen cases reached their actual browser, search, catalog, MCP and notification
checks; the browser/search/catalog case also verified its unsent chat draft.
The only failure on all three platforms came after the notification checks:
the test sought the root Chat control while still inside the Task notifications
navigation page. Each failed AX snapshot shows its native back button and no
root Chat control. The driver now taps that observed back button before the
unchanged final draft assertion. This is a test candidate, with **no native pass
claimed until a rerun**. [Three-run method and artifact evidence](evidence/ui-language-dfd-three-runs.json).

## SE native core at `dfd6eff`

[Run 42958707611](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42958707611)
passed **345/345 native and hosted App methods**, zero failures and zero skips,
on iPhone SE (3rd generation) / iOS 18.5. The full 819-member artifact ZIP
passed CRC and SHA-256 verification. The XCTest summary, completion gate and
345 unique method start/pass events agree. This source includes the language,
PDF and MCP test-driver candidates through `dfd6eff`; their separate UI shards
remain independent. The later website media-permission changes need their own
native compile result. [Method-level evidence](evidence/native-se-dfd6eff.json).

## Exact iOS 17 native core at `dfd6eff`

[Run 42958720550](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42958720550)
passed **345/345 native and hosted App methods**, zero failures and zero skips,
on iPhone 15 / iOS 17.0.1 (21A342). The full 818-member ZIP passed SHA-256 and
CRC verification; the XCTest summary, workflow completion gate and 345 unique
method start/pass events agree. This validates the selected core scope only;
separate language, PDF, MCP and browser UI failures or pending shards remain.
The workflow's `runtime_tested` field is reserved for `test_scope=all`; the
actual XCTest device and selected runtime both identify iOS 17.0.1.
[Method-level evidence](evidence/native-exact17-dfd6eff.json).

## Dual-PDF UIDocument candidate: one platform passes, two fail

The isolated `9600dfb` candidate creates the two synthetic PDF fixtures through
`UIDocument.save(to:for:.forCreating)`. The unchanged focused method passed
**1/1 on exact iOS 17.0.1**, with two native picker callbacks, two read grants,
the expected A2/B1/A1 PDF page order, unchanged source files and the result
retained after cancelling export. It failed **0/1 on current iOS 26.2** after
the first of two picker callbacks, and **0/1 on SE/iOS 18.5** before the first
callback; both had two successful fixture save/close events. Each failed run
contains a nearby FileProvider `-1005` diagnostic, which does not establish
causation. All three artifact ZIPs passed SHA-256 and CRC checks. The candidate
remains isolated; its iOS 17 pass is not a cross-platform fix.
[Run and artifact evidence](evidence/pdf-pair-uidocument-9600-three-runs.json).

## Website camera and microphone request boundary

At `8c79a66`, Debug and Release Info.plists gained camera and microphone
purpose strings. Apple requires purpose strings when an app uses those protected
resources; both plists passed `plutil -lint` and key-presence checks. At
`1fb3aea`, the iOS WebKit media-capture delegate returns `.prompt` only for a
visible, manually browsed page in the selected tab; it returns `.deny` for new
requests from hidden tabs, model-owned documents, clearing sessions or a page
dialog. It does not auto-grant access. At `4a5e658`, the same delegate source
compiled in the actual macOS App/WebKit harness in Debug and Release; controlled
browser regression passed **172 assertions each**, plus iOS syntax parsing.
This is **not** native iOS typechecking or a camera/microphone permission flow
test. [Local source and check evidence](evidence/browser-media-macos-typecheck-4a5e658.json).
Current native compile/core run
[42962749795](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42962749795)
is pending; physical capture, already-active streams and iOS 17 system prompts
remain unverified. [Apple WebKit default prompt](https://developer.apple.com/documentation/webkit/wkuidelegate/webview%28_%3Arequestmediacapturepermissionfor%3Ainitiatedbyframe%3Atype%3Adecisionhandler%3A%29),
[Apple purpose strings](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media).

## MCP UI after iOS 17 keyboard correction

At `b4e8c70`, current completed **4/8** and SE **7/8** MCP UI methods, zero
skips. At `221a080`, the exact iOS 17.0.1 rerun completed **7/8**, zero skips;
all three learning cases cleared the old keyboard-geometry check. On SE and
exact17, the remaining learning case completed remote and memory approvals,
received its result and final reply, then stopped when the test sought a
`完成` result-sheet button while the product labeled it `完成輸入`. The product
now uses the existing localized Close text and a stable `mcp.results.close`
identifier; the test retains all later undo and relaunch assertions. Current
also had one unrelated setup navigation failure before any approval, still
unresolved. All three shards require fresh native acceptance.
[Method and artifact evidence](evidence/ui-mcp-b4-and-221-failures.json).

## iOS 17 archived PDF disclosure selector identified

At `189796c`, the exact iOS 17.0.1 documents-chat shard completed **2/3**,
zero skips. The bounded AX snapshot before the failed lookup shows the exact
`archive.turn.0.pdf` identifier on a visible `DisclosureTriangle` with the
synthetic PDF filename. The prior test queried that identifier as a `Button`
and stopped before citation, saved-page, reopen and deletion checks. Both
archived PDF disclosure lookups now use XCTest's disclosure-triangle query;
all later assertions and time limits remain. A native rerun is required.
[Source, artifact and bounded AX evidence](evidence/chat-pdf-exact17-disclosure-189796c.json).

## Exact iOS 17 startup interface after streaming selector correction

At `cacd8f0`, [run 42952165858](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42952165858)
passed **15/15 ui-startup methods**, zero failures and zero skips, on iPhone 15 /
iOS 17.0.1. The complete artifact ZIP passed CRC verification; the summary,
completion gate and 15 unique method start/pass events agree. The formerly
failing completed-stream method now reached and passed its exact answer,
notification and durable archive assertions. Current and SE correction reruns
remain separate. [Full artifact and method evidence](evidence/ui-startup-cacd8f0-exact17-pass.json).

## Current and SE chat PDF interface failures

The SE/iOS 18.5 `a663fbd` documents-chat shard completed **2/3** and the
current/iOS 26.2 `b4e8c70` shard completed **1/3**, both with zero skips. Their
full-answer cases selected a PDF, obtained two grants, received a model reply,
saved and reopened the archive, then stopped while revealing a saved citation.
The current cancellation case also stopped earlier: a native Files thumbnail tap
delivered neither a selection callback nor an actionable Open control within the
existing 15 seconds. A test-only diagnostic now records bounded, redacted AX
state immediately after archive disclosure and fixed picker-state booleans on
that wait failure. It does not change App behavior or accept either failed case.
[Source-bound failure evidence](evidence/chat-pdf-current-se-failures.json).

## Three-platform language interface failures and scoped correction

At `e37b641`, the language UI shard completed **3/5**, zero skips, on each of
current iOS 26.2, SE/iOS 18.5 and exact iOS 17.0.1. The three established
language cases passed; both new English-screen cases stopped before their
business assertions. On current and exact17, the native keyboard-switch button
was a sibling of the Keyboard AX node and the test searched only within that
node. On SE, English was selected but the resolved-language row was below the
small-screen viewport while the test waited for it before scrolling. The test
now uses the exact bilingual keyboard label across app buttons and reveals the
localized row before its bounded existence and exact-text checks. These are
test-driver corrections; native reruns remain required.
[Run and failure evidence](evidence/ui-language-e37-three-failures.json).

## Current notification interface at `a663fbd`

[Run 42947630736](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42947630736)
passed **2/2 UI methods**, zero failures and zero skips, on iPhone 17 / iOS
26.2. The complete artifact ZIP passed CRC verification, and each selected
method started and passed once. A system approval banner opened the same pending
proposal; execution occurred only after one explicit approval. The settings
banner returned to root Chat, and notification preference changes survived
relaunch. Both methods recorded `audibleSoundVerified=0`; sound and physical
device behavior remain unverified. [Source and artifact evidence](evidence/ui-notifications-current-a663fbd.json).

## Current native core at `a663fbd`

[Run 42947685010](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42947685010)
passed **345/345 native and hosted App methods**, zero failures and zero skips,
on iPhone 17 / iOS 26.2. The complete artifact ZIP passed CRC verification;
the XCTest summary, completion gate and 345 unique starts and passes agree. This
includes the later streaming, PDF and notification logic at `a663fbd`; separate
interface shards remain unaccepted where their own runs fail or await execution.
[Method-level artifact evidence](evidence/native-current-a663fbd.json).

## Three-platform browser workspace failures and scoped corrections

At `83f4ddd`, the workspace UI shard completed **5/9** with zero skips on each
of current iOS 26.2, SE/iOS 18.5 and exact iOS 17.0.1. The same four methods
failed on each: two login/website-clear cases and custom search stopped at the
native keyboard switch before their business assertions; the page-find case
reported zero results but its native arrows did not expose a Disabled AX state.
The login and custom-search tests now select the observed bilingual native
keyboard label. The find test
checks the zero count, actually taps both arrows when safely hittable and requires
the query, URL, count and original visible match to remain unchanged. These are
**native test candidates**, with no pass claimed until rerun.
[Method-level three-run evidence](evidence/ui-workspace-83f-three-failures.json).

## Dual-PDF per-file coordination experiment rejected

The isolated `c59c134` per-file coordinated creation candidate failed its one
focused native method on **current iOS 26.2, SE/iOS 18.5 and exact iOS 17.0.1**:
0/1 passed and zero skips on each. Current failed on the first selection; SE
received A then failed on B; exact17 failed on the first selection. Current and
SE system logs identify FileProvider `-1005` and no URL returned; the exact17
artifact proves no callback but lacks that provider log. Creation and post-test
hashes do not establish the file's state at tap time. The candidate remains on
its isolated branch and is **not accepted as a product fix**.
[Three-run artifact and method evidence](evidence/pdf-pair-filecoord-c59-three-failures.json).

## Unsigned iPhoneOS device build

At `eebb019`, [run 42950596606](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42950596606)
completed an **unsigned iPhoneOS build** with Xcode 26.2, minimum iOS 17.0 and
nine verified binaries. The downloaded report and build log have matching hashes;
the log contains one `BUILD SUCCEEDED` and no build errors. This proves device
compilation only. It produced no installable signed IPA and ran no physical-device
tests. [Full artifact and report evidence](evidence/unsigned-device-eebb019.json).

## iOS 17 MCP keyboard geometry

At `b4e8c70`, the exact iOS 17.0.1 MCP UI shard completed **5/8**, zero skips.
Three learning cases stopped before their MCP approvals because the test required
the entire native keyboard switch frame inside the app frame; its bottom extended
0.4 pt beyond the screen while the control was hittable and its center was inside.
The test now checks the tappable center while retaining the hittability check,
actual keyboard switch, subsequent input and consent assertions. Native rerun is
pending. [Method and geometry evidence](evidence/ui-mcp-b4e-exact17-geometry.json).

## Archived PDF native accessibility diagnosis

At `a663fbd`, the exact iOS 17.0.1 chat PDF shard completed **2/3** with zero
skips. The full-answer case reached PDF selection, both grants, model response,
archive save and relaunch, then failed looking up the visible saved PDF disclosure
as a `Button` by identifier. The video proves the row is rendered, but the prior
artifact lacks its AX role and identifier. A bounded, redacted AX snapshot is now
recorded immediately before the unchanged lookup. The original test remains
failing until a native run identifies the row and the remainder of the archive,
citations, reopen and delete flow passes. [Diagnostic scope and limits](evidence/chat-pdf-archive-ax-diagnostic-cacd8f0.json).

## iOS 17 streaming UI failure and scoped selector correction

At `a663fbd`, the startup UI shard completed **14/15**, zero skips, on each of
current iOS 26.2, SE/iOS 18.5 and exact iOS 17.0.1. The same completed-stream
case reached the partial reply, then failed looking up its selectable assistant
text as `StaticText`; XCTest reported the same identified UILabel with computed
AX type `Other`. The test now queries that exact identifier across AX types,
preserves its exact answer/notification/archive assertions and the existing
time limit. Native proof of this correction is still pending in three reruns.
[Current and SE source-bound failures](evidence/ui-startup-a663fbd-current-se-failures.json),
[exact17 failure](evidence/ui-startup-a663fbd-exact17-failure.json).

## Current native core at `50e2b74` — 2026-11-11

The iPhone 17 / iOS 26.2 native and hosted integration run
[42945328369](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42945328369)
passed **341/341 methods, zero failures and zero skips**. The complete downloaded
artifact ZIP passed its CRC check; its SHA-256, XCTest summary, completion gate,
and 341 unique method starts and passes match. This is core and hosted App
coverage at the named source revision. It does not accept the separate UI shards,
the later keyboard changes, iOS 17, signing, or a physical device.
[Method-level evidence](evidence/native-current-50e2b74.json).

## Manual address search integrated; observed browser driver failures retained — 2026-11-11

Manual address input now uses pinned Mika's Bing default, four built-in engines and persisted custom templates, with escaped queries and history query restoration. The additive encrypted-library field preserves existing tabs, bookmarks, history and site modes. Switching engines does not reload the page or grant model research capabilities. Custom template entry has normal Next/Done keyboard actions. [Behavior and differences](MANUAL_BROWSER_SEARCH.md).

Independent source execution exposed malformed `http:` / `https:` inputs falling back to remote search. The same new regression first failed, then passed after rejecting these malformed schemes; `site:` operators remain accepted. The actual App check also confirms rejected input does not create another WebKit navigation. **127 pure assertions** are included in **170 actual App assertions each Debug/Release**, with existing site modes **118 each**. Find regression passed **50 each**, HTTP navigation **26**, and HTTP site-mode behavior **12**. **277 Python tests**, actionlint, XcodeGen and syntax checks passed. The new inventory is **96 non-Live UI methods**, workspace **9**. [Integration proof](evidence/manual-browser-search-integration-local.json).

A separate public-service App/WebKit probe reached Bing results (HTTP 200, 10 result nodes, matching query). Its Google attempt reached HTTP 200 but an additional main-frame navigation was blocked by the probe's original budget, so that attempt remains incomplete, not a product-failure diagnosis. Two manual opens, no retry or model calls; macOS 13 WebKit only, not iOS acceptance. [Preserved first service attempt](evidence/manual-browser-search-public-services-first.json).

The prior `bb5c9eb` workspace results remain current **6/6**, SE **4 passed / 2 failed**, and exact17 **5 / 1**, all zero skips and each method once. [Full three-run proof](evidence/ui-workspace-bb5c9eb.json). The site-mode candidate now closes the actual WebKit keyboard and targets its verified innermost menu button. The SE website-clear failure was a secure-field snapshot interrupted inside a short predicate waiter while the field was still partly obscured; the candidate moves geometry evaluation back into the existing bounded scroll loop, retaining full containment, three-scroll and 420-second case limits. [SE failure analysis](evidence/site-clear-se-bb5c9eb-password-diagnosis.json), [driver scope](evidence/site-clear-se-driver-local.json). Neither correction is accepted until its new native run completes.

The separate exact17 UIKit open-in-place diagnostic case remains failed before any picker callback; ordinary open/copy cases passed in the same run. Its [original evidence and screenshot](evidence/ios17-documents-read-8c4195f-picker.json) remain separate from the other picker failures.


## Native suite accepts transcript/PDF-add/site-mode increment — 2026-11-11

At `bb5c9eb`, [run 42919356039](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42919356039) passed **321/321 native and hosted App methods, zero failures/skips**, on iPhone 17 / iOS 26.2 / 23C54. Every method started/passed exactly once; xcresult summary and completion gate agree. Parent verified the entire downloaded artifact ZIP digest. The portable run separately passed **216/216**; overlapping counts are not added.

Newly accepted native methods include four PDF-add App cases, eight transcript-reference core/App cases and three site-mode core/App cases. This does not accept the later common preference header, streaming, page-find or search changes, and does not replace the failed exact17 site-mode UI operation. [Source/runtime/method proof](evidence/native-current-bb5c9eb.json).


## Exact iOS 17 baseline completed; memory readiness correction — 2026-11-11

Nine remaining runs at `8c4195f` now have source/runtime/method/xcresult and full artifact ZIP digest evidence. Native core and hosted App methods passed **306/306** on iOS **17.0.1 / 21A342**, zero skips. Independent UI partitions passed browser **5/5**, profile **9/9**, memory tools **6/6**, skills **10/10**, and MCP **8/8**. Learning was **3 passed / 2 failed**, memory **7 / 1**, and documents-read **5 / 1**; none is relabeled a pass. Counts across suites/revisions are not added. [Per-run evidence](evidence/exact17-8c-remaining-shards.json).

The memory failure occurred before the first Save, while readiness polling did not resolve the visible keyword field. Its candidate driver uses native existence polling, then hittability only if needed, sharing the original five-second deadline. All test bodies, data assertions, failure-stop behavior and product sources are unchanged. Debug/Release syntax parses and exact patch scope checks passed; actual iOS behavior awaits a separate run. [Preserved failure and driver evidence](evidence/memory-exact17-readiness-driver-3de917a.json).

The documents-read open-in-place case failed waiting for an importer callback at 87.273 seconds; it remains distinct from the exact17 pair accessibility failure and current/SE FileProvider failures. Further diagnosis is required, not a shared-cause assertion.


## Plain chat streaming, page find and UI driver corrections — 2026-11-11

The integrated candidate adds plain ChatSession text streaming with a display-only partial reply. Completion alone can create an archive turn, learning input or completion notification. Cancellation retains the draft and explicitly unfinished preview; request identity prevents late output from an older request. Profile/memory and MCP structured flows retain their reviewed complete-response path. Debug-only UI fixtures require the isolated namespace and explicit fixture mode, and are excluded from Release.

The separate actual-service App probe at its recorded `7b2fb3e` plus v2 source hashes made **two HTTP stream attempts, no retry**: one completed after 175 text deltas and reopened from an encrypted archive; the second cancelled after two observed deltas while its HTTP transport was still active. Partial output never entered the archive, no completion notification was added for cancellation, and learning bytes were unchanged. These are parser text events, not network packets. The probe uses a synthetic OS notification client and does not establish a native banner, sound or UI result. Its completion counters and join observe the App/probe wrapper, not socket closure; transport cancellation is separately covered by intercepted URLProtocol stopLoading assertions. [Exact-source live evidence](evidence/live-chat-streaming-app-local.json).

Browser page find uses the native WebKit find panel and clears its session across navigation, tab changes, hidden views and automation ownership. Local macOS checks cover the real WebKit engine and existing HTTP/site-mode behavior; UIKit controls and actual iOS rendering require the new three hosted and two UI methods. [Behavior and boundaries](BROWSER_PAGE_FIND.md).

The original `8c4195f` exact17 documents-output partition remains **8 passed / 1 failed / 0 skipped**. Unlike the current/SE no-callback FileProvider failures, the failed exact17 pair case accepted source A and then stalled in an accessibility query after Files dismissed. [Original evidence](evidence/ios17-documents-output-8c4195f.json). Its driver now queries exact source ID/full filename via firstMatch during transition, then verifies uniqueness; distinct files, approvals, digests, page order, cancellation and 15/300-second bounds remain. Python and the actual workflow shell gate both allow the existing focused pair scope to prebuild under unchanged hosted-fixture conditions. [Local correction evidence](evidence/pdf-pair-ax-transition-local.json).

The two failed exact17 multi-source research cases use the inner TextView tap and native keyboard check already exercised by passing BrowserLearning cases. Prompts, exact input readback, results, citations, deduplication and isolation assertions remain. [Preserved failure and candidate driver correction](evidence/multisource-exact17-focus-driver-d9cb6a4.json). These changes are candidates until their native reruns complete.

Parent integration on the current common-preference source passed stream checks **101 Debug / 75 Release**, existing chat **573 / 492**, archive **90 / 76**, intercepted transport **310**, and context **48** assertions. Actual WebKit find passed **50 each**, HTTP navigation **26**, existing site modes **118 each** and HTTP Cookie/POST behavior **12**. All **277 Python tests**, actionlint and XcodeGen passed; source hashes remained unchanged. [Integration evidence](evidence/stream-find-driver-integration-local.json). These executions are not additive native test counts.

The UI inventory now assigns all **95 non-Live methods to 12 disjoint partitions**, including startup 15 and workspace 8. New UI methods have no skip path; source-bound integration checks are recorded separately from native acceptance.


## Compatible saved preferences clarified — 2026-11-11

The common reference message now explicitly asks for saved language/format/style preferences when compatible with the current request. Current explicit instructions and fixed policy still win. References remain user-role JSON data and cannot supply source evidence, authorize actions or add tools; complete-entry 6000-character/24-KiB bounds are unchanged.

The original local PDF-reference probe failed after four actual HTTP calls: it completed search/two reads/answer/two citations but did not match the saved exact prefix. Raw answer was not retained, so the prefix failure category and root cause cannot be reconstructed; later ledger/storage checks were not reached. Its exact probe and [original failure evidence](evidence/live-document-query-references-8c-local.json) are preserved at `3eeaa2d`.

One source-changed validation passed **2/2 local real-model App cases** with eight new requests: saved preference, then explicit current-request override. Both exact prefixes, read-ledger citation bytes, original source and encrypted-storage preservation passed; the second answer excluded the old prefix. Cumulative requests were **12**, no repeat after result. [Live evidence](evidence/live-document-query-references-3a84-local.json). This demonstrates these two runs, not the cause of the older failure or universal compliance.

Parent integration passed actual PDF App checks **391 each Debug/Release**, transcript App regression **238 each** plus **17 core suites each**, and 68 pure diagnostic assertions, with source hashes verified. [Integration evidence](evidence/reference-preference-integration-local.json). The earlier exact17 PDF UI pass did not seed preferences; native acceptance of this header change remains separate.


## Real-model PDF query completed on exact iOS 17 — 2026-11-11

At `956aa9f`, `testRealModelAnswersFromApprovedPDFAndExportCancellationPreservesResult` passed **1/1, zero skips**, in **223.730 seconds** on iOS **17.0.1 / 21A342**. The fixed audit records four model calls, one search, two reads, one result, two citations and zero corrections. Native copy selection, separate read/extract approvals, query, exact citations and exporter cancellation completed; unchanged answer/citations/audit were verified at 185 seconds and the original extraction after returning at 211 seconds. The 300-second test and 285-second cleanup boundaries are unchanged. Parent independently checked the test source hash, actual completed method and fixed phase/audit log markers. [Safe evidence](evidence/live-document-query-956-ios17.json), [run](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42913237285). The original `f49c8f7` timeout remains recorded. This case does not seed a saved preference and does not establish preference effectiveness or a causal performance improvement from one run.

At `8c4195f`, notification interface regression also completed **2/2 each, zero skips** on exact iOS 17.0.1, SE/iOS 18.5 and iOS 26.2. [Evidence](evidence/ui-notifications-8c4195f.json). This verifies controls and navigation, not audible notification or a physical device.


## Native PDF selection diagnosis extended — 2026-11-11

Current and SE `8c4195f` logs place the failed selection before any App callback: the exact synthetic filename is selected, FileProvider reports `NSFileProviderErrorDomain -1005` for its local item identifier, and DocumentManager obtains no URL. This does not establish why the provider item is unavailable or whether the original file still existed at the precise failure. Independent local creation/re-entry checks found no App deletion path. The observed provider identifier is not a filesystem inode. [Preserved failure evidence](evidence/pdf-assembly-add-8c4195f.json).

The diagnostic increment records only the two strictly gated synthetic pair files: creation, each explicit picker presentation and actual callbacks, followed by the existing post-test inventory. It compares bytes, filesystem identity, hashed URL and parent directory identity. It adds no timer, selection retry or replacement picker path; the same two real selections, approvals, output checks and 300/15-second limits remain. Local real-PDF/POSIX identity checks and Debug/Release gates passed. Native diagnosis is pending, not a product repair. [Pair evidence](evidence/pdf-assembly-pair-identity-local.json), [parent integration](evidence/pdf-pair-runtime-diagnostics-integration.json).

The unrelated `8c4195f` exact17 workspace job failed during the 120-second simulator runtime inventory, before build or any of its five UI methods. New reporting preserves this timeout and exit 1 while adding fixed operation/category/elapsed fields; it makes no retry. All 265 tooling regressions passed, including real-child timeout/nonzero/launch failures and output privacy checks. [Original preflight evidence](evidence/ui-workspace-8c4195f-preflight.json).


## Manual browser site modes integrated — 2026-11-11

Manual mobile/desktop preferences now persist by normalized hostname in the existing encrypted browser library. A confirmed manual GET reloads once after the explicit mode change, with Cookie storage retained. POST, unknown-method and automation-owned documents defer until the next manual navigation. The navigation delegate retains existing URL/origin/method/download restrictions; mode selection grants no new network or model authority. Details and pinned Mika behavior: [manual website display preferences](MANUAL_BROWSER_SITE_MODES.md).

The integrated source passed actual macOS WebKit checks **118 each in Debug/Release**, plus **12 actual loopback HTTP assertions** including server-observed one-GET reload, retained HttpOnly authentication and no POST replay. Existing research checks passed **238 core assertions** and **378 App assertions each in Debug/Release**. Python tooling: **259/259**; actionlint and XcodeGen passed. The three new core/hosted methods and one UI method are registered without a skip branch; non-Live UI inventory is **91 methods in 12 partitions**. [Source-bound local evidence](evidence/manual-browser-site-modes-local.json). iOS rendering/native execution remains pending; macOS returned effective mode `.recommended` for both preferences. The actual HTTP-specific harness is local Debug evidence, not native iOS HTTP acceptance.

## Exact iOS 17 startup interface — 2026-11-11

At `8c4195f`, the startup/settings partition passed **13/13, zero skips** on iPhone 15 / iOS 17.0.1 / 21A342. Each expected method started and completed once; xcresult and completion report agree, and the downloaded artifact ZIP SHA256 was independently verified. Tests cover navigation, configured chat fixtures, draft/cancellation/error behavior, model/MCP credential separation and appearance persistence. [Evidence](evidence/ui-startup-8c4195f-exact17.json). These are synthetic transport/UI checks, not real model/MCP or later-source acceptance.


## Archive UI completed and live replay diagnosis — 2026-11-11

At `8c4195f`, completed-conversation archive UI passed **4/4 each, zero skips** on exact iOS 17.0.1/21A342, iPhone SE/iOS 18.5 and iPhone 17/iOS 26.2. Each source method started/completed once, with matching xcresult counts. Coverage includes explicit reopening, destination mismatch, delete/relaunch and excluding cancelled/unsent work. [Evidence](evidence/ui-archive-8c4195f.json). This does not accept later product changes or physical devices.

The separate actual-model/WebKit replay-reference probe retains its original **FAIL**: saved preference passed, current-request priority matched but no successful route receipt was saved. One authorized repeat of the same failed case passed, with unchanged goal/preferences/page hashes, an independent `done` judgment, two accepted evidence citations and encrypted readback. **Six HTTP attempts/responses total**; no further calls. The first failure did not retain the judgment category, so the repeat does not prove a fix or identify its cause. Answer URL/prefix checks are not a semantic correctness proof. [Source-bound evidence and limitations](evidence/live-replay-references-local.json). Harness publication checks: 28/28, zero private response/configuration output; actual iOS acceptance remains separate.


## Transcript references and actual cancellation integrated

The Files, catalog and approved browser-text transcript entries now capture the same
LearningStore only after explicit Start. Saved memory/profile/compatible skills are
user-role references before the selected format request, never source citations or
extra tool authority. Edits remain frozen; deletion/disable/reload/clear stop the run.
An actual held-model test exposed that the old task group kept the run alive after
cancellation. The new one-shot completion releases the App task before that model
returns and rejects its later result. The original 24 calls, cumulative 180-second
model wait, one correction and byte limits remain unchanged.

Parent isolated integration passes **238 actual App assertions and 17 core suites**
in each local configuration, **231 Python tests**, actionlint and XcodeGen; real HTTP
entry points compile without executing. Three new core and five hosted methods are
registered; native/UI/live behavior remains pending. [Integration proof](evidence/transcript-reference-integration-local.json),
[original failure and regression](evidence/transcript-reference-cancellation-regression.json),
[behavior and remaining boundaries](TRANSCRIPT_REFERENCES.md).


## Archive UI passes two devices; PDF add remains under investigation

At `8c4195f`, archive UI passed **4/4** on each of
[current iOS 26.2](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42911167014)
and [SE / iOS 18.5](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42911171619),
zero skips. Real encrypted rows survive relaunch, open only explicitly, remain
readable but cannot continue under changed model identity, and stay deleted after
relaunch. Cancelled runs and unsent drafts are not claimed as saved.
[Per-method/runtime/source proof](evidence/ui-archive-8c4195f.json). Exact17 remains separate.

The new deliberate PDF-add flow still failed on both
[current](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42911177308)
and [SE](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42911183701),
each **0/1**. These failed at different stages: current delivered A but had no
nativePicked event after the B touch; SE had no nativePicked event after the first
A touch. Both system picker screens remained visible. The visible thumbnail checks
and synthesized coordinates do not prove that the native control accepted selection.
No shared root cause, stale callback or OS/provider defect is established.
[Native events, failure frames and limits](evidence/pdf-assembly-add-8c4195f.json).
The strict distinct-source, approval, page-order and export assertions remain required.


## Integrated native suite completed at 8c4195f

[42911161821](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42911161821)
passed **306/306 native/hosted methods, zero skips**, on iPhone 17 / iOS 26.2 /
23C54. The separate portable suite passed **212/212**; these executions overlap
and are not additive coverage. Each method started and completed exactly once;
xcresult and the completion gate agree. The complete artifact ZIP was independently
downloaded and its SHA-256 verified. This covers 3 archive core and 6 actual App
methods, 6 replay-reference App methods, and all 10 PDF-query core / 9 App methods.
[Source hashes, actual methods and artifact proof](evidence/native-current-8c4195f.json).
This accepts that source's native logic, not its separate UI runs, later hosted
PDF-add tests, in-flight transcript/site-mode changes, or full product parity.


## Prior-source exact17 output and SE profile acceptance

At `1abc6d7`, [42902041641](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42902041641)
passed all **9/9 documents-output methods, zero skips**, on iPhone 15 arm64 / exact
iOS 17.0.1 / 21A342. The old two-file batch selection passed in this environment;
its current-iOS failure remains preserved. This is prior-flow evidence and does not
accept the subsequent deliberate-add replacement. [Exact methods and runtime](evidence/ios17-documents-output-1abc6d7.json).

At the same source, [42902029485](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42902029485)
passed **9/9 profile UI methods, zero skips**, on iPhone SE / iOS 18.5. Each selected
method completed once, with xcresult and source checks. [Bounded evidence](evidence/ui-profile-1abc6d7-se.json).

## Conversation archive, saved references and deliberate PDF addition integrated

The new conversation archive stores completed question/answer pairs in a dedicated
local encrypted vault, with explicit list/open/delete and retry after a failed save.
Restoring never resumes unfinished commands or approvals; continuation requires the
same endpoint, model and credential identity. Actual App checks pass 90 Debug / 76
Release assertions, with 573 / 492 existing chat assertions and 30 independent
review assertions. Native SwiftUI and four new archive UI cases remain pending.
[Archive checks](evidence/conversation-archive-app-local.json),
[independent review](evidence/conversation-archive-independent-local.json).

Saved memory/profile/compatible skills now reach route replay and PDF questions at
explicit start. Deletion, disabling and cancellation invalidate in-flight work.
Local route checks pass 239 assertions per configuration; PDF question App checks
pass 357 per configuration, including the corrected standalone live-harness build.
These local counts are not native UI acceptance or actual-model behavior claims.
[PDF references and corrected harness provenance](evidence/document-query-references-local.json).

PDF assembly now selects one file at a time and offers explicit Add PDF controls,
up to three sources. Each addition clears prior grants and requires fresh read and
assembly review; cancellation preserves existing output. Local Debug/Release checks
pass 53 new and 57 existing App assertions each. The two-file native test retains
separate file identities, two real picker callbacks, approvals and exact A2/B1/A1
output. This replaces the inconsistent batch flow without asserting an OS fix.
New native runs must validate this combined source revision.
[Exact deliberate-add local checks](evidence/pdf-assembly-sequential-add-local.json).

The isolated integration snapshot passes 231 Python tests, actionlint, XcodeGen,
fixture diagnostic guards and whitespace checks. Hosted replay/archive tests and a
separate four-case archive UI shard are registered; iOS 17 UI inventory is now 90
non-Live methods across 12 disjoint shards, plus 22 Live methods.



## Notification approval matrix completed at f49c8f7

The same two native notification cases passed on all three fresh simulators at
`f49c8f7`: SE/iOS 18.5 [42902405880](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42902405880),
Large/iOS 18.5 [42902411329](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42902411329),
and current/iOS 26.2 [42903185255](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42903185255).
Each is **2/2, zero skips**: six executions of two distinct methods. Every device
verified actual OS banner/default-open routing before approval, the same pending
proposal UUID, and one explicit approval followed by exactly one fixture call.
Settings permission, relaunch and disable also passed. [Evidence index and source
boundary](evidence/task-notifications-f49-final-snapshot.json). The later archive
UI changes are outside that tested source snapshot; audible sound, physical
devices and independent browser/skill-runner notifications are not covered.

## Exact iOS 17 document reading completed; two-file batch import failed separately

At `1abc6d7`, [42902035480](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42902035480)
passed **6/6 documents-read methods, zero skips**, on exact iOS **17.0.1 / 21A342**,
iPhone 15 arm64. This includes actual original/coordinated/UIKit open/copy and
user-chosen-copy selection plus picker cancellation without a read. Each selected
method started and completed once. One prebuild preceded the fresh simulator;
194.522 seconds were deducted from the unchanged 1800-second build/test budget.
The simulator was deleted afterward. [Runtime, methods and limitations](evidence/ios17-documents-read-1abc6d7.json).
The same opt-in ordering is now available for the other non-Live UI shards;
[231 isolated Python checks and actionlint pass](evidence/prebuild-ui-shards-local.json).
That infrastructure extension alone is not native acceptance of those shards.

At `92a9ef4`, [42901181555](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42901181555)
failed the new two-PDF batch case **0/1** on iOS 26.2. Video shows both distinct
files checked before Open, but the App completion received one URL and prepared
one source. The adapter forwards the complete callback array; current evidence
does not establish the underlying OS/provider cause. Both-file read approval,
interleaved assembly and export were not reached. The strict two-source assertion
and original failure remain preserved; an explicit user-driven add-file path is
being implemented as a separate workflow. [Failure and selection frame](evidence/pdf-assembly-multi-92a9ef4.json).

## SE notification approval and learning UI completed

At `f49c8f7`, [42902405880](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42902405880)
passed **2/2 notification UI methods, zero skips**, on iPhone SE / iOS 18.5. The
actual OS approval banner was tapped; the callback changed the route generation
inside the still-pending sheet while retaining the original proposal UUID. One
subsequent explicit native approval produced exactly one fixture tool call/result.
The separate settings case passed notification permission, actual banner/default
open, relaunch persistence and disable. Transport/model content was synthetic;
audible sound and physical-device behavior were not verified. Large/current
continuations remain separate. [Exact event order and attachments](evidence/task-notifications-approval-42902405880.json).

At `1abc6d7`, [42902024042](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42902024042)
passed **5/5 learning UI methods, zero skips**, on iPhone SE / iOS 18.5 / 22F77.
The three browser-learning and two multi-source methods each started/completed
once, including model-setting removal cancellation, website-knowledge relaunch,
pending-skill manual approval/relaunch, source quotes and duplicate-origin refusal.
These are native fixture flows, separate from real public-site/model acceptance
and the subsequent replay-reference changes. [Method and source proof](evidence/ui-learning-1abc6d7-se.json).

## Combined native regression and device compilation completed

At `1abc6d7`, [42902018558](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42902018558)
passed **286/286 native and hosted methods, zero skips**, on iPhone 17 / iOS 26.2 /
23C54. The separate portable execution passed 207/207; these totals are not
additive unique coverage. Actual starts, completions and xcresult counts agree.
The nine new multi-source reference methods and ten existing LearningRun App
methods with expanded lineage/cancellation assertions all passed.
[Exact methods, source hashes and limits](evidence/native-current-1abc6d7.json).
The separate profile and learning UI checks remain distinct acceptance.

At `f49c8f7`, [42902524475](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42902524475)
completed unsigned Release device build **57** with Xcode/SDK 26.2. The release
verifier checked nine binaries, minimum iOS 17.0, native document settings and
required-reason entries; ATS exceptions were absent. The downloaded report ZIP
matches its GitHub digest. This is **not an installable signed build**, physical
runtime acceptance or App Store upload. [Build proof](evidence/unsigned-device-f49c8f7.json).

## PDF question and profile UI completed; actual reference behavior verified locally

At `ae381fc`, [42900646333](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42900646333)
passed the complete actual-model PDF question UI case on iOS 18.5, **1/1, zero skips**,
in 275.255 seconds. Four real model calls produced two verified page citations.
Native export cancellation preserved the answer and citations, and returning to
the original extraction preserved its exact text and operation audit at second 264.
The 300-second allowance and 285-second cleanup boundary were unchanged; private
configuration and the owned simulator were cleaned. [Fixed phases and counts](evidence/live-document-query-ae381fc-ios18.json).
The exact iOS 17.0.1 continuation is a separate acceptance run.

At `7b0b89a`, [42895988211](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42895988211)
passed all **9/9 profile UI methods, zero skips**, on iPhone 17 / iOS 26.2 / 23C54.
The actual per-method log and xcresult agree; the original `4f26118` failures remain
preserved. This run predates the later replacement-lineage product fix.
[Exact methods and source hashes](evidence/ui-profile-7b0b89a.json).

The production multi-source runner, HTTP client and actual macOS WebKit passed
three real-model reference cases: saved preference, current-request precedence and
citation isolation. All nine citations match actual observed ranges from both
approved public roots. Saved entries were synthetic; no user vault was captured.
An additional synthetic forged-command replay was rejected without network access.
The first attempt failed without an HTTP subtype; a bounded diagnostic observed
HTTP 400 and a model-selection mismatch with the existing CI configuration. Changing
only that model selection produced three valid completions. Five client attempts
were used across all attempts, within the shared twelve-call ceiling. This does
not establish a provider-wide defect or native iOS UI acceptance.
[Complete bounded evidence and preserved attempts](evidence/multi-source-references-live-fixture.json).

## Exact iOS 17 startup completed after prebuild

At `e963698`, [42893709163](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42893709163)
passed the single startup method on exact iOS 17.0.1 / 21A342, iPhone 15 / arm64,
with zero skips. A successful 180.240-second `build-for-testing` preceded creation
and cold boot; one `test-without-building` used the same generated manifest path.
The method completed in 28.527 seconds. The shared budget and completion gates
were unchanged. This does not establish the original bootstrap stall's root cause,
a separately verified daemon handshake, PDF flow or full iOS 17 acceptance.
[Bounded original commands, events and manifest-hash limits](evidence/ios17-prebuild-startup-e963698.json).

## iOS 17 PDF and two notification variants completed

At `aa676a3`, exact iOS 17.0.1 / 21A342 completed both PDF assembly flows:
[original](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42897576797)
1/1 in 167.713 seconds and [explicit copy](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42897582946)
1/1 in 152.902 seconds, zero skips. Both selected one two-page PDF and completed
reordering, separate output approval and native export cancellation with the result
preserved. [Exact runtime and method evidence](evidence/ios17-pdf-assembly-aa676a3.json).

At `7b0b89a`, the original notification UI case passed on both
[SE / iOS 18.5](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42895974099)
and [current / iOS 26.2](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42895981647),
each 1/1 with zero skips. Actual permission, system banner, tap-to-root Chat and
persisted opt-in/opt-out all completed. Audible sound and the added pending-approval
case are separate. [SE evidence](evidence/task-notifications-native-42895974099.json),
[current evidence](evidence/task-notifications-native-42895981647.json).

The real-model PDF question case at `7b0b89a` failed before the Done tap: its new
wait helper rejected an already-ready native control after a slow synchronous AX
read. No model request occurred. `ae381fc` repairs that readiness handling while
retaining the full 300-second case and 285-second cleanup boundary, original
question, native operations and exact citations. Sixteen local wait regressions
pass; the old helper fails the reproduced scenario. [Original native failure](evidence/live-document-query-7b0b89a-ios18.json),
[local correction](evidence/document-query-wait-regression-local.json).

The new two-distinct-PDF native case at `92a9ef4` is pending. Local checks pass
48 Debug / 24 Release with real PDFKit, separate read grants, actual interleaved
output and negative output/original-file checks. It never injects a picker selection
or grants authorization through fixture data. [Scope and hashes](evidence/pdf-assembly-two-source-local.json).

## Multi-source references integrated; new native acceptance pending

Multi-source research now reads immutable profile, memory, approved skills and
knowledge for the explicitly approved roots. The same snapshot is checked around
model and browser awaits; removing captured data cancels the pending run. Local
checks pass 36 new core, 74 existing core, 197 Debug / 31 Release App assertions,
plus single-site App 378/378 and unchanged Chat regressions. A captured profile
replacement followed by deleting that replacement now revokes its ancestor;
late-reply checks wait for actual run completion before testing side effects. The new explicit combined context
ceiling retains actual receipts and never promotes saved text into citations.
[Exact scope and local reports](RUN_REFERENCES.md). Nine added native methods
(four core, five hosted App) are registered; local macOS execution is not iOS acceptance.

At `f28d0bb`, SE / iOS 18.5 [42890996168](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42890996168)
passed all five browser-learning and multi-source UI methods, zero skips. It proves
those source-pinned flows and predates this multi-source reference integration.
[Methods and exact source](evidence/ui-learning-f28d0bb-se.json).

The additional notification case is explicitly registered: a real system approval
banner must reopen the same pending proposal UUID, leave it unexecuted, and execute
exactly once only after the native approval tap. The UUID observation is restricted
to the strict isolated DEBUG fixture; fourteen parser/gate checks and syntax checks
pass locally. OS delivery and this complete native flow remain pending.
[Case scope](TASK_NOTIFICATION_APPROVAL_NATIVE_PLAN.md).

## Integrated references and notifications passed native logic checks

At `f28d0bb`, [42890964046](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42890964046)
passed **277/277 native/hosted methods, zero skips**, on iPhone 17 / iOS 26.2.
Portable execution separately passed **203/203**. All 28 new methods completed:
8 notification core, 4 reference-context core, 10 actual learning-reference App
and 6 actual notification App methods. These overlap the core layer; they are not
480 distinct features. [Exact methods and source hashes](evidence/native-current-f28d0bb.json).

The separate native notification UI case at the same revision failed **0/1**.
Its actual recording shows the fixed system banner at about 26–28 seconds, with
an App icon and title/body, without a separately rendered App-name text. The old
matcher required that extra name label. The candidate now matches exact fixed
fields inside a bounded SpringBoard subtree; attribution still requires tapping
that actual banner and reaching this App in the foreground, with root Chat visible
and the pushed notification settings gone. Failed observations retain a bounded
transient AX candidate and screenshots. Both SE and current native retests passed at `7b0b89a`, as recorded above.
[Original failure and recording observation](evidence/task-notifications-native-42890969758.json).

The older `4f26118` profile matrix completed **6/9 by xcresult, zero skips**;
console text alone misleadingly recorded a timed-out delete method as passed.
The two other failures were an initial App-launch timeout and a history disclosure
remaining collapsed after a tap. Candidate helpers immediately evaluate unchanged
readiness predicates and target the exact visible history label once, then await the actual expanded state within the existing 10-second readiness bound; all nine
method bodies, data checks and 240-second limits remain unchanged. Launch failure
is not claimed fixed. [Original method-specific evidence](evidence/ui-profile-4f26118.json).


## PDF assembly: SE, Large original and current user-copy completed

At `f28d0bb`, the ordinary SE / iOS 18.5 case
[42890982515](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42890982515)
passed **1/1, zero skips**, in 196.177 seconds. The explicit user-copy case on
current iOS 26.2 [42890975618](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42890975618)
also passed **1/1, zero skips**, in 227.597 seconds. Both returned exactly one
selection callback, separately approved the actual two-page read and output,
entered the exact reversed page order, produced a two-page PDF, and received a
native export-cancel callback while retaining the identical exportable result.
[Per-device stages and source hashes](evidence/pdf-assembly-f28d0bb.json).
These cases select one two-page PDF in a picker allowing multiple selection;
this does not accept cross-file merging. The Large / iOS 18.5 original case
[42890989077](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42890989077)
also passed 1/1, zero skips. [Final three-case evidence](evidence/pdf-assembly-f28d0bb-final.json).

## Actual PDF question: retained result reached, whole-case deadline still failed

At `517d0d1`, [42885607583](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42885607583)
failed **0/1, zero skips**. Real selection, extraction, four model calls, two exact
page citations, actual native export cancellation and retained answer/citations
were observed; the unchanged 300-second allowance expired before query close and
final original-extraction readback. The late cancellation marker is not a pass.
[Fixed stages, timing and exact missing steps](evidence/live-document-query-517d0d1-ios18.json).

The new driver evaluates already-ready predicates immediately and reads visible
query rows together using a fresh scoped accessibility snapshot, while still
performing real bounded scrolls for unreadable rows. Exact question, destination,
read/extract approvals, answer/citations, native cancellation and original-result
retention assertions remain. Whole-case 300 seconds and cleanup boundary at 285
seconds remain unchanged. This is a native retest candidate, not a claimed App
performance fix or E2E success.

## Task references and notification integration awaiting native acceptance

Single-site research now captures profile, active memory, eligible approved personal
skills and website knowledge once per run, with one combined 6000-character /
24000-byte limit. Ordinary edits affect the next run; disabling memory, deleting
captured entries, clearing storage and reload revoke the active snapshot. Saved
references remain data, not navigation approval or source evidence. Local shared
checks passed 33 assertions, and actual App/WebKit checks passed 174 per Debug and
Release, plus existing research (238) and ChatSession regressions (573/492).
The final coherent snapshot is recorded separately from the owner handoff.
[Scope and evidence](RUN_REFERENCES.md).

Two concrete regressions were reproduced before correction: a replaced profile
followed by deleting an unrelated entry incorrectly revoked the active reference;
an already-cancelled valid browser-link operation still started navigation. The
latter now reports zero loading starts, unchanged URL and no document claim.
[Before/after evidence](evidence/learning-run-reference-regressions.json). This
covers the deterministic cancellation entry, not every possible in-flight race.

Default-off local task notifications now connect to the actual root ChatSession,
including MCP and profile/memory review states. Local checks passed 154 core,
136 Debug App and 121 Release App assertions, including a reproduced/fixed
permission-request versus refresh race. These construct real UNNotificationRequest
objects but do not access a live notification center. Native permission, banner,
tap-to-root navigation and persisted opt-in/opt-out are separate UI acceptance;
independent browser/skill runners are not wired yet. [Scope and evidence](TASK_NOTIFICATIONS.md).


## Source discovery: actual search, explicit selection, separate research approval

The research form now offers a separate DuckDuckGo HTML search sheet. Only actual observed organic-result links can become candidates; tracking redirects are not decoded into guessed destinations. The isolated WebKit adapter has fixed navigation/resource policies, no page JavaScript, a shared 45-second deadline, cancellation fences and no automatic fallback. Native selection requires two or three distinct origins, and Apply only replaces source fields. It never starts research or converts search snippets into body citations.

Local acceptance passed **127 assertions**: 85 shared core checks, 28 real macOS WebKit/lifecycle checks and 14 actual public-search checks. The one actual search loaded an HTTP 200 page and produced ten candidates individually matched to DOM anchors. An initial navigation rejection exposed Foundation's trailing-slash path representation; the correction uses the serialized path while preserving the exact allowed URL. [Original failure, source hashes and public search evidence](evidence/research-source-discovery-local.json). One successful query is not universal provider coverage or iOS acceptance.

The initial production App Session passed 81 assertions in each of Debug and Release. A later actual WebKit integration exposed that leaving after a completed search did not revoke its selected candidates. `cancel()` now clears that completed result and selection. The new shared regression fails against the original `395ee5a` Session and passes after the correction: **100 assertions / seven groups in each configuration**. Two actual public searches then passed **54 checks**, using the production Session, adapter and observed DOM; each returned ten candidates across seven origins. Applying the two selected candidates starts no research or body reads, and leaving/query changes revoke old candidate IDs. [Current local and real-search evidence](evidence/research-source-discovery-app-live-local.json). This is macOS WebKit execution, not native iOS UI acceptance; the new seventh hosted regression and the two actual-search UI cases remain separate CI acceptance.

## Completed-selection revocation passed native regression

At `bbbb514`, [42884124056](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42884124056) passed **249/249 native/hosted methods, zero skips**, plus **191/191 portable methods**. All seven production source-discovery App methods completed, including the new regression that prevents applying a completed search after leaving or backgrounding. [Exact methods, runtime and source hashes](evidence/native-current-bbbb514.json). This accepts that App logic on iOS 26.2; it does not substitute for the independently running PDF or actual-search UI cases, or the later notification/reference work.

## Current completed-selection correction: actual search UI

At `bbbb514`, [42884145269](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42884145269)
passed **2/2 actual-search UI methods, zero skips**, on iOS 18.5 (177.313 and
150.264 seconds). Both searches returned ten real candidates. Selection applied
two distinct origins in order without starting research, and reopening/closing
preserved the intended parent fields. The second method observed fast completion,
not cancellation; completed-result revocation is established by the separate
hosted regression above, not these UI cases.
[Exact paths and limitations](evidence/live-source-discovery-bbbb514-ios18.json).

## Latest native build and controlled PDF picker comparison

At `395ee5a`, [42879183146](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42879183146) passed **248/248 native/hosted methods, zero skips**, with **191/191 portable methods** separately passing. This includes four source-discovery core and six App-session methods; it predates the completed-result cancellation correction above. [Source-specific method evidence](evidence/native-current-395ee5a.json). The same revision also completed an unsigned iphoneos Release build: MinimumOS 17.0, all nine Mach-O binaries verified, no DEBUG compiler flag or ATS override. It is **not installable, signed, uploaded or runtime-tested**. [Build evidence](evidence/release-unsigned-device-395ee5a.json).

Exact iOS **17.0.1 / 21A342** at `ad461cf` completed **5/6 document-output methods, zero skips**. PDF export/cancel, both refusal paths and worker-setting persistence passed. Assembly stopped before text entry because the synthesized tap landed on the page-order field's upper edge and did not focus it. The paired read shard started **zero of six methods**: XCTest control-session initialization failed; the synthetic runner error is not a document-method failure. [Output evidence](evidence/ios17-documents-output-ad461cf.json), [bootstrap evidence](evidence/ios17-documents-read-ad461cf.json).

The separate SE/Large assembly cases reached selection and read approval, then failed because five backspaces from a middle caret left `1-2`. The common harness now taps inside the exact visible field, uses one native Select All action, deletes once, checks empty and enters the exact reversed order. It retains original callback/case limits and every approval/output assertion. A DEBUG-only UIKit open/multiple-selection arm now runs the identical workload against the original SwiftUI importer. Both arms **select one two-page PDF in a picker that permits multiple selection**; this is not cross-file native merge acceptance. Local checks passed **217 Python tests**, 55 Debug/49 Release picker gates and 17 invalid-live-fixture cases. Native retesting remains required. [Original failures](evidence/pdf-assembly-ad461cf-order-edit.json), [controlled comparison and source hashes](evidence/pdf-assembly-open-multi-local.json).

## Original PDF assembly failures and explicit copy path

At `bbbb514`, all three ordinary assembly device jobs failed: SE and Large each
returned one picker callback and read both PDF pages, then failed to reveal the
focused page-order field; current iOS returned no selection callback. The separate
UIKit open/multiple-selection experiment also returned no callback. The exact
17.0.1 job booted but started zero methods because the XCTest runner was killed
during bootstrap. These are distinct failures, not five failed assembly assertions.
[All five terminal jobs and original evidence](evidence/pdf-assembly-bbbb514-final.json).

The candidate targets the focused field's own Form scroll viewport and adds an
explicit user-facing **import a PDF copy** option with a copy disclosure. It keeps
both read and output approvals, exact page-order editing and native export-cancel
checks. Original SwiftUI open, DEBUG UIKit open and user-chosen copy each have
separate selectors. All select one two-page PDF while allowing multiple selection;
none proves native cross-file merge. Local 24 Debug/26 Release import-mode checks
and seven shared scroll-geometry checks passed; the new native cases still require
execution. [Source hashes and local limits](evidence/pdf-assembly-copy-local.json).

## Actual profile recall and master-switch acceptance

At `017976b`, [42868747738](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42868747738) passed **1/1 actual-model UI case, zero skips**, on iOS 18.5 in **98.688 seconds**. A synthetic randomized profile was typed and saved through the native editor, then survived process relaunch and was recalled exactly by the real model. After turning off the real persisted master switch and relaunching again, the same question returned exactly `UNKNOWN`; the stored profile remained intact with recall disabled. [Pinned source, exact counts and sequence](evidence/live-profile-recall-017976b.json). This closes the older toolbar-helper failure for this scenario, not all memory/browser runners or physical-device acceptance.

## Actual profile tool review and persistence passed

At `f737665`, [42868043180](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42868043180) passed **1/1 actual-model profile UI, zero skips**, on iOS 18.5 in **92.638 seconds**. The real model proposed `profile_edit`; native review showed the exact user quote and replacement text before any receipt. Approval saved exactly one entry and produced a nonempty answer. Relaunch preserved the exact text and entry ID without replaying the chat or creating false history. [Pinned source and safe completion evidence](evidence/live-profile-tool-f737665.json). Profile recall/master-switch and the full fixture matrix remain separate scenarios.

## Current iOS memory-tool UI regression completed

At `46d25c4`, [42880165194](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42880165194) passed **6/6 ordinary memory-tool UI methods, zero skips**, on iPhone 17 / iOS 26.2. Every expected method completed once. The former save/undo/relaunch timeout now passed in 144.598 seconds; delete/undo/relaunch passed in 143.499 seconds. All six test bodies are byte-identical to `61f5377`; only their shared immediate-predicate path changed, with the original assertions and deadlines retained. [Exact method hashes, runtime and completed results](evidence/ui-memory-tools-46d25c4.json). The earlier SE/Large successes and current failure remain pinned to their original revision, not relabeled as this run.

## Document native acceptance and ordinary memory UI

At `ad461cf`, [42874419743](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42874419743) passed **238/238 native/hosted methods, zero skips**, including all eight new document-query core methods and six production App-session methods. Portable execution separately passed **187/187**. These are overlapping layers, not 425 distinct features. [Pinned source and actual method evidence](evidence/native-current-ad461cf.json). This is not native Files/query/export interaction acceptance.

At `61f5377`, [42866520782](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42866520782) passed all **6/6 ordinary memory-tool UI methods on each of SE and Large / iOS 18.5**, zero skips. Native review, refusal, update/delete/undo, separate procedure approval/rejection and relaunch persistence all completed once. The iPhone 17 / iOS 26.2 job finished **4/6, two 240-second timeouts, zero skips**: save/undo timed out at the final pending-list check after relaunch, and delete/undo timed out during relaunch without a normal completion line. The candidate fixture only evaluates the same predicate immediately before entering its unchanged bounded wait; every data, undo and relaunch check remains. Its effect requires a new native run. [Device-specific evidence and original failure timelines](evidence/ui-memory-tools-61f5377.json).

## Actual source discovery and HA mixed acceptance completed

At `395ee5a`, [42879189446](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42879189446) passed **2/2 real-search iOS 18.5 UI methods, zero skips**, in 227.573 and 200.643 seconds. Actual candidates from two distinct origins were applied exactly in selection order without starting research; reopening starts a fresh sheet and closing preserves parent fields. Both searches returned ten candidates. The second case observed fast completion (`cancellationObserved=0`), so it does not establish cancellation. [Exact native paths and source hashes](evidence/live-source-discovery-395ee5a-ios18.json). This revision predates the completed-result revocation correction in `bbbb514`, whose native rerun remains separate.

At the same revision, [42879196152](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42879196152) passed **1/1 actual HA/model mixed UI case, zero skips**, in **222.451 seconds**. Three model decisions and one HA call completed without tool errors or format repair. Separate remote/local reviews, exact memory content and receipt, saved-list readback, native undo, and relaunch with empty active/pending memory all completed. [Safe counters, full path and original failure](evidence/live-mcp-memory-395ee5a-ios18.json). This closes the fixed-receipt viewport failure below for that scenario, not all MCP tools or iOS17 coverage.

## Original HA mixed failure retained


The real HA/model case at `f737665`, [42868021734](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42868021734), failed **0/1, zero skips, 162.874 seconds**. The actual remote review, memory review and exact final answer completed with three model decisions, one HA attempt/result, no tool error and no format repair. The subsequent receipt assertion used the message-scroll viewport for a fixed sibling outside that scroll view. Receipt/note readback, undo and relaunch checks were not reached. The correction only targets those fixed controls in the new mixed method and preserves the original 300-second cap and data assertions. [Original failure and safe counters](evidence/live-mcp-memory-f737665.json). The corrected native rerun above passed at `395ee5a`.

## Current MCP UI and remaining profile / picker failures

At `61f5377`, [42866536800](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42866536800) passed **8/8 MCP UI methods, zero failures/skips**, on iPhone 17 / iOS 26.2. This includes all three mixed local-learning cases: remote result then reviewed memory and undo/relaunch, saved profile preserved after remote refusal, and declined local memory with no remote attempt or persisted item. These use synthetic model/MCP fixtures; the separate real HA/model UI remains pending. [Exact methods and xcresult metadata](evidence/ui-mcp-61f5377.json).

The same revision's [profile UI run](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42866528420) passed **8/9, one failure, zero skips**. All four former composer failures passed. The remaining case still showed clear-all stage 1 after a native Continue tap inside its actual visible frame. The cause is unproven. A diagnostic correction scopes the controls to that sheet and requires stage 2 on both cancellation and destructive branches; it does not add a second tap, increase the ten-second wait, or claim a product fix. [Original tap/AX and candidate hashes](evidence/ui-profile-61f5377.json).

PDF assembly failed separately on [SE](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42866580966) because its byte receipt contained a valid thousands separator, and on [current iOS](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42866563988) because Files remained presented after Open with the exact source selected. The latter never reached read approval and is not covered by the receipt parser correction. [SE evidence](evidence/pdf-assembly-61f5377-se.json), [current evidence](evidence/pdf-assembly-61f5377-current.json).

The first document-query native dispatch at `ad461cf` had a source-reviewed observation wiring defect: the passive picker probe required the local experiment gate, which deliberately rejects live-model launches. The correction supplies only the validated synthetic fixture namespace to a passive probe, independently of experiment mode. User selection, picker implementation, delegate handling and approvals are unchanged. Debug/Release fixture guards and syntax checks pass; this is not native selection acceptance. The original actual-model App logic report retains its captured pre-correction source hashes. A corrected native live run is required.

## Actual native PDF query: answer passed, export cancellation unfinished

At `4f26118`, [42875111573](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42875111573) failed **0/1 actual-model iOS 18.5 UI case, zero skips**, at the unchanged 300-second case limit. Native selection and two read/extract approvals completed, followed by four real model calls, one search, two actual reads and two verified citations, without format repair. The later native export-folder transition reached the driver's cleanup-reserve boundary before cancellation and retention checks completed. [Original fixed-stage timing and evidence](evidence/live-document-query-4f26118-ios18.json). This is not a model or query correctness failure, but the full E2E case remains failed. The candidate helper checks the same exact question after dismissing the keyboard, targeting the observed long AX delay; native retest is required.

## PDF text tools and query integration

The PDF result now exposes a separately consented model query over its immutable extracted pages, using bounded search/read operations and actual-read IDs for verified original-page quotations. The App preserves the question and source on cancellation, invalidates destination consent on configuration changes, and exports only a completed answer through the native destination picker. [Exact capability and provenance boundaries](SKILL_RUNTIME.md).

Core validation passed **218 assertions / eight shared test groups**, with real PDFKit and warnings treated as errors. Tests include real extraction then removal of the original file, repeated page selections, UTF-8 boundaries, malformed/duplicate commands, hostile integers, actual read-ID citations, shared budgets, cancellation and late results. Captured source hashes remained current. [Full local evidence](evidence/document-query-core-local.json). This is not native XCTest acceptance; separate App and real-model results follow below.

The production App Session and immutable FileDocument separately passed **136 assertions / six groups in each of Debug and Release**, using actual PDFKit extraction, real isolated encrypted settings, dynamic actual-read IDs and disk write/readback. This covers consent before requests, settings/key changes, cancellation and a late old response after a newer delivery, explicit retry, audit counters and preserving completed output. The first local build exposed a missing framework import in the standalone exporter configuration; the source now supports both framework and same-module compilation without replacing a production type. [Source hashes and actual group results](evidence/document-query-app-local.json). Local UI checks are syntax-only. A separate actual-model run then passed with **four HTTP requests / four responses in 15.026 seconds**, using the same production Session, real approved PDFKit extraction, literal search, page reads, validated exact quotes and immutable FileDocument disk export/readback. The original PDF was removed before the model query; no synthetic model reply was supplied. Completed output survived access invalidation with no extra request. Both 136-assertion configurations also passed again and captured source hashes remained current. [Actual run evidence](evidence/document-query-app-live.json). This remains macOS execution of production App logic; native iOS sheet, Files and export acceptance is pending.

## SE learning retest completed

At `61a94d6`, [42861671702](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42861671702) passed **5/5 UI methods, zero failures/skips**, on iPhone SE / iOS 18.5. All three browser-learning flows and both multi-source fixture flows completed exactly once, including cancellation when settings are removed, pending skill approval/relaunch, exact observed citations and duplicate-origin rejection. [Actual method completion and summary](evidence/ui-learning-se-61a94d6.json). This closes the two SE helper failures recorded at `74f7b71`; real public-model research is a separate run.

## Exact iOS 17 documents: completed methods, two real assertions, incomplete result bundle

At `61a94d6`, [42861694796](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42861694796) ran all twelve selected document UI methods on **17.0.1 / 21A342**. Logs record **ten passed and two failed**, with no skipped method events. The result bundle did not finalize before the 1800-second bound, so there is no certified successful summary and no acceptance claim. The two daemon samples contained only an initial dyld frame; they do not identify an internal bootstrap cause. [Original logs, video-backed observations and bounded diagnostics](evidence/ios17-documents-bootstrap-61a94d6.json).

The two actual failures are test-format assumptions. PDFKit inserted layout whitespace inside the synthetic UUID; the revised helper compares the entire two-page output after removing only ASCII layout whitespace, preserving every marker, UUID character, hyphen and page order. Native receipt labels format the byte count as `8,373`; a strict bounded parser now accepts valid comma grouping while still requiring exactly two pages and a positive size within the existing input/output limits. Forty-five local assertions cover invalid identities, added/missing text, bad grouping and oversize counts. Original picker, read/assembly approvals, output order and export cancellation checks remain.

A default-off diagnostic comparison can suppress Xcode's large post-failure system collection only when the owned-process bounded sampler has initialized. It changes no assertion, method result, retry policy or case deadline. Log-only progress is explicitly diagnostic and cannot replace successful xcresult verification. Native retests remain required.

## Native learning baseline and real HA/memory UI acceptance

At `61f5377`, [42866511159](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42866511159) passed **224/224 native/hosted methods, zero skips**, including all 23 profile/memory/MCP App integration methods and six local-MCP core methods. Portable tests passed **179/179**. [Actual completions, source hashes and runtime](evidence/native-current-61f5377.json). This is native logic acceptance, not UI acceptance for every flow.

At `61a94d6`, [42861631222](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42861631222) passed **213/213 native/hosted methods, zero skips**, on iPhone 17 / iOS 26.2, including all 18 profile/memory App-hosted methods. Portable Swift tests independently passed **173/173**. [Unique actual method completions and source hashes](evidence/native-current-61a94d6.json). This predates the MCP/local integration in `61f5377`; its regression runs are separate.

The real-model ordinary-memory case at `61a94d6`, [42861716124](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42861716124), passed **1/1 native UI, zero skips**, on exact iOS 18.5 in 168.793 seconds: the typed request produced a separately reviewed write, approval saved exactly one item, native undo removed it, and relaunch left active and pending memory empty. [Fixed observations and actual method completion](evidence/live-memory-tools-61a94d6-ios18.json). It does not test the separate mixed-MCP turn or physical devices.

The real HA workflow now has an isolated `memory-learning` scope. Its new native UI case selects only `ha_eval_template`, verifies the exact arithmetic arguments before approval, then separately reviews the synthetic preference write. It requires the actual remote result and model completion, one saved memory, native undo, and an empty encrypted memory store after relaunch. Existing native HA protocol probes and private configuration cleanup remain. This raises the inventory to **81 non-Live / 19 Live** methods; the new method is not a pass until its native run completes.

## MCP conversations now dispatch reviewed local learning tools

The host offers local profile/memory actions separately from the selected remote MCP catalog. Exact raw arguments survive parsing; only the actual current utterance may authorize writes. The existing twelve model calls, six remote operations and 180-second deadline remain; local actions share the model budget and add no remote authorization. Local search is limited to one, profile/memory share one mutation, and one final model call is reserved before dispatching a local action. After native review the host rechecks the callback lease and request, then synchronously checks store state and atomically persists.

Local verification passes **145 local-action checks**, **498 existing MCP checks**, and **five profile-flow groups**. Native XCTest is unavailable on this CLT host; the same test bodies execute standalone and the XCTest wrapper is syntax-parsed, not falsely reported as native-tested. [Core report](evidence/mcp-local-core-local.json). The actual App and real isolated AES-GCM files pass **573 Debug / 492 Release** with current source hashes at completion: remote/local approvals stay separate; local search returns actual IDs; refusal, cancellation, disconnect, master switch, clearing, stale revision and file-write failure cannot commit; remote text cannot authorize memory; a second local mutation cannot consume a separate profile allowance. [App source and assertions](evidence/mcp-learning-app-local.json).

A separate actual-model/HA run passes **five real model calls, one approved remote call/result, zero tool errors**, in **12.176 seconds**. The one remote action evaluates the exact fixed arithmetic template; the host verifies the actual result before approving a synthetic memory write. The result and committed memory ID reach the model, encrypted reopening succeeds, and undo remains empty after reopening. A second turn commits a synthetic profile then refuses the remote proposal: **zero second-turn remote attempts**, with the profile receipt, encrypted data and draft preserved. [Bounded real-service evidence](evidence/live-mcp-learning-app-local.json). This is macOS production App logic with test-driven reviews, not native iOS UI or personal data. Three new mixed native fixture cases are wired, expanding the exact inventory to **81 non-Live / 18 Live** methods. The unchanged MCP/learning sources were tested before the separate research prompt clarification below.

## Actual two-source research passed on iOS

At `61f5377`, [42866589370](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42866589370) passed **1/1 actual-model UI, zero skips**, on iOS 18.5 in **146.692 seconds**. The real IANA and RFC Editor pages were read, both supplied exact requested example-domain citations, and the result completed without a partial marker. Closing the result left skills/pending empty. [Pinned source and safe completion evidence](evidence/live-multi-source-61f5377.json). This passes the previously failing two-root scenario, not the later search-discovery feature or arbitrary websites.

## Multi-source completion: clarify actual gaps versus provenance cautions

The `856e8ec` real-model iOS run [42853430458](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42853430458) passed native JSON/SSE probes but failed **0/1 UI, zero skips**, after two pages were read and the App finished without a product error. The result was marked partial; later citation assertions were not reached. The original limitation text was not retained. [Actual failure](evidence/live-multi-source-856e8ec.json).

A separate real macOS WebKit/model execution of the same public-source question reproduced a specific cause: both sources contributed exact requested domain quotes, but a publisher-independence caution occupied the unresolved-limitations list. The prompt now directs interpretation/provenance cautions into finding text when they leave no requested question unanswered, while preserving genuine missing evidence as limitations. **No parser, citation assertion, partial classifier, call budget or deadline changes.** One candidate execution completed with both exact source quotes and no unresolved limitations. [Baseline/candidate hashes and bounded evidence](evidence/multi-source-provenance-prompt-local.json). This is not a statistical guarantee or proof of the original iOS response cause; the unchanged native acceptance still needs to run.

## Composer geometry and native Files confirmation corrections

The `856e8ec` actual-model manual-profile run [42853423972](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42853423972) failed **0/1, zero skips**, in 75.463 seconds, before saving the profile or making a model request. The five-second `exists/hittable/enabled` toolbar predicate expired; the later fixed diagnostic observed the Save control present, enabled, hittable and inside the App, with the keyboard absent. This does not establish its readiness within the original deadline. The helper now polls only [native hittability](https://developer.apple.com/documentation/xcuiautomation/xcuielement/ishittable), then explicitly checks existence, enabled state and geometry before its single tap. The wait and all profile outcome assertions remain unchanged; the new helper needs native retesting. [Original timing and bounded evidence](evidence/live-profile-toolbar-856e8ec.json).

At `856e8ec`, the current-iOS memory/profile shard completed **13/17 passes, four failures, zero skips**. All four new profile-tool cases failed before typing: the test tried to reveal the sibling chat composer inside the message ScrollView. Fixture AX places the visible composer below that ScrollView and above navigation. The repaired helpers check actual screen/navigation/keyboard bounds and native hittability; exact typing, approvals, receipts, undo and relaunch assertions remain. The equivalent helper in the new memory-tool tests receives the same fix. [All original actual method events](evidence/memory-ui-856e8ec.json). These test changes are not native passes until retested.

The `30bcaf1` Large PDF assembly case failed **0/1, zero skips**, in 132.538 seconds after file selection but before the App callback: the native Files navigation bar exposes its confirmation as `打開`. The helper now includes that exact native label alongside `開啟`/`Open`, retaining its navigation-bar scope, readiness checks and single tap. [Original fixture AX, frame and callback evidence](evidence/pdf-assembly-confirmation-30bcaf1-large.json). It does not weaken read/assembly approvals, output ordering or export-cancellation checks.

## Ordinary memory tools: local transactions and real-model App checks

Ordinary chat now dispatches `memory_search`, `memory_save` and `memory_edit` through the production memory state, with actual search-result IDs, current-utterance grounding and explicit native review before atomic encrypted writes. Pending procedures still need activation approval. The tools share the profile flow's three foreground calls, one search, one mutation and 90-second budget; post-answer automatic extraction is a separate background call. MCP-mode integration was subsequently added in `61f5377`, described above. [Behavior and deliberate Mika differences](MEMORY_TOOLS.md).

Core checks pass **245 memory-tool assertions / ten groups**, plus the existing **97 profile-tool / 91 memory-state** assertions. A real App regression first failed when preference changes removed a deleted-memory undo card; filtering against actual undo eligibility fixes it. The same targeted case now passes **84/84**. Final production App logic and isolated AES-GCM checks pass **468 Debug / 395 Release**, including 44 actual fixture-client checks. No iOS SDK is used locally. [Before/after App evidence and source hashes](evidence/memory-chat-app-local.json), [core baseline](evidence/memory-tools-core-local.json), [undo eligibility correction](evidence/memory-tools-can-undo-local.json).

A separate real-model run used the production HTTP client and App logic for **29 actual model calls, zero model errors, 57.745 seconds**: profile add, ordinary-memory save, actual search followed by delete and undo, pending-procedure approval, and 20 conversation turns retaining all 40 messages. An oversized prompt preserves draft/history without another request. Every committed stage is read back from the real isolated encrypted file. Two earlier failed probes are retained: the first was unclassified; the second produced a review whose exact text/quote assertions failed. Adding explicit quotes to the synthetic request left those strict assertions unchanged; the original returned strings were not retained, so no punctuation cause is claimed. This macOS run predates the later undo-card fix, uses synthetic records and test-driven approvals, and does not establish native UI or physical-device acceptance. [Hashed source and bounded live evidence](evidence/live-learning-tools-app-local.json).

At `856e8ec`, [42853401159](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42853401159) passed **193/193 native/hosted methods, zero skips**, on iPhone 17 / iOS 26.2, including **10/10 profile App integration methods**. Portable Swift tests independently passed **161/161**. This source predates the new ordinary-memory tools. [Unique actual completions and runtime evidence](evidence/native-856e8ec-current.json).

The `61a94d6` inventory partitioned all **78 non-Live UI methods** exactly once: memory 8, profile 9, memory tools 6, and the other existing shards, with **18 live methods** separately selected. Later mixed-MCP additions expand that inventory as recorded above; inventory counts and local parsing are not executed UI results.

## SE user-selected PDF copy completed end to end

At `2d7da70`, [42854821854](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42854821854) passed **1/1, zero skips**, in 182.785 seconds on iPhone SE / iOS 18.5. The actual Files picker delivered exactly one success callback; the App audit progressed through separate read/extract approvals to the completed result, with both exact page markers and separator verified. The picker was ready within the former 45-second bound in this run, so the new 60-second ceiling is not established as the reason for success. [Complete actual callback/audit/output evidence](evidence/file-provider-user-copy-2d7da70-se.json). This does not pass the separate open-in-place or multi-file assembly paths.

## Three-device learning retest retains two compact failures

At `74f7b71`, [42847901710](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42847901710) completed **13/15 UI methods, zero skips**: current iOS 26.2 and Large iOS 18.5 each passed 5/5; SE passed 3/5. Both multi-source methods passed on every device. SE failed during a settings-control query and a keyboard-disappearance wait; fixture video and accessibility evidence show the target control visible and the keyboard already dismissed. The test-helper repair retains five-second waits, one native tap, exact text, cancellation/no-late-learning and save/relaunch assertions. [Original per-method evidence](evidence/ui-learning-74f7b71.json). Native retesting is required for the repair.

## SE native login retest completed

At `856e8ec`, [42853412343](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42853412343) passed **1/1 native login UI, zero skips**, in 105.218 seconds on iPhone SE / iOS 18.5. Real form POST, authenticated protected requests, cookie reuse in another tab, relaunch with no new login POST, and logout denial all passed. The QuickPath test helper uses one public snapshot to locate the real native Continue control; password/login assertions are unchanged. This validates the synthetic local account flow, not external OAuth/MFA compatibility. [Actual completion evidence](evidence/browser-login-856e8ec-se.json).

## Exact iOS 17 bootstrap diagnostics: bounded sampling experiment

Deeper public diagnostic logs from the failed `74f7b71` document run show about **271 seconds between testmanagerd's xpcproxy spawn and executable-running event**. RunningBoard later terminated the UI runner when its `XCTRunner Initialization` assertion expired. These establish the bootstrap timeline, not the underlying scheduling/exec cause. [Bounded original events](evidence/ios17-bootstrap-stall-74f7b71.json).

An opt-in hosted-fixture experiment now samples only the invocation's owned daemon/runner identities at most three times. Each command is bounded to 15 seconds, strips raw headers/arguments/paths, discards changed identities and stops when an actual test starts. It neither restarts the targets, retries XCTest nor extends the original test deadline. All **190 Python script tests** pass locally, including the sampling gates, cleanup and live-runner snapshot validation; actual iOS 17 sampling remains unverified until its CI run. The selected document suite still requires all twelve real methods to complete.

## Reviewed profile tool and bounded chat history: local integration complete

Ordinary chat now offers one reviewed `profile_edit` per turn. The host checks the exact current utterance, stale state and master switch, then atomically persists before returning a receipt. Review rejection and failed persistence cannot publish success; a later model failure retains the actual committed receipt. Duplicate JSON argument keys remain visible to the strict parser. This is an additional explicit user review compared with Mika's prompt-authorized profile tool.

Local checks passed **97 tool assertions**, **3 flow groups**, **48 context-window assertions**, and **213 Debug / 184 Release actual App assertions**. App checks use the unchanged production logic and real AES-GCM files with synthetic model replies and isolated key stores. Twenty completed turns retain all 40 displayed messages; the last window contains 32 messages (15 recent pairs, complete reference and current prompt), plus the Flow system instruction. An oversized current prompt preserves draft/history without another model request. [App checks and source hashes](evidence/profile-chat-app-local.json), [tool checks](evidence/profile-tool-core-local.json), [flow checks](evidence/profile-chat-flow-local.json). Ten Debug hosted XCTest methods, four fixture UI methods and one actual-model method are wired for native acceptance; local macOS checks do not establish iOS execution.

The completed `faf7536` memory UI matrix is **32/39 passed, 7 failed, zero skipped**, with all expected methods completed. Three failures exposed missing keyword fixture data; two stopped on native profile-input predicates; two iOS 26 skill cases failed native save/segment hittability. Candidate test repairs preserve exact input, native taps and all business assertions, with no additional retry or method allowance. [Full failed matrix and repair evidence](evidence/memory-ui-faf7536.json). These repairs require a new run.

At `74f7b71`, native iOS 18.5 Large and iOS 26.2 each passed **169/169**, including all five PDF assembly methods; SE remained queued at evidence collection. [Actual event counts](evidence/native-74f7b71.json). This result predates the profile-tool batch above and is not its acceptance.

## Exact iOS 17 document UI did not start

The `74f7b71` document run [42847908760](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42847908760) booted exact **17.0.1 / 21A342**, built the App and runner, but executed **zero of twelve expected methods**. The summary's one failure is a runner-bootstrap error. Session evidence records a 120-second daemon control-session timeout, followed by runner termination before any method starts. The opt-in prelaunch observed process liveness in 0.844 seconds without a verified handshake; this did not prevent the failure. [Bounded log/summary evidence](evidence/ios17-documents-74f7b71-bootstrap.json). The daemon's underlying stall remains unknown; no App document assertion failed or passed in this run.

## Exact iOS 17 actual HA MCP flow passed

At `dabe9bf`, [42833543641](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42833543641) passed **3/3 actual App UI methods, zero skips**, on exact **17.0.1 / 21A342**. Discovery/disconnect/reconnect, two approved read-only model-selected tools and refusal/draft preservation all executed in one XCTest invocation. The two-tool conversation used three model calls, two actual attempts/results, and zero corrections/tool errors. Native HA probing and App build passed separately. [Fixed runtime, counts and lifecycle evidence](evidence/live-ha-dabe9bf-ios17.json).

The one-shot daemon prelaunch observed process liveness in 3.479 seconds; its handshake flag remains false. Actual method starts/completions establish execution independently. This success does not prove prelaunch caused improvement, explain the earlier bootstrap failure, or cover a physical device.

## Native copy/open comparison and research UI failures retained

The same `e09db96` source completed the UIKit import-copy case **1/1** and failed open-in-place **0/1**, both with zero skips on iPhone 17 / iOS 26.2. Copy delivered one actual callback and completed both approvals plus exact two-page output; open delivered no callback and never reached read approval. Provider/resolver codes were observed only in the failed arm. These were separate jobs and fixture namespaces, not a controlled identical-state comparison. [Full bounded comparison](evidence/file-provider-open-copy-e09db96.json). Default picker reliability and the newer explicit user-copy entry still require their own acceptance.

The `1ea3d08` three-device learning shard [42828125356](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42828125356) completed **9 passed / 6 failed / zero skipped**. All nine existing browser-learning instances passed. All six new multi-source instances failed before entering the first root URL: the keyboard remained visible and the helper selected its suggestion collection as the Form scroll container. The `80a1121` test now checks each exact typed value and dismisses the keyboard through its actual Done button before advancing. [Original method evidence](evidence/ui-learning-1ea3d08.json). Retest: [42842709484](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42842709484).

The separate actual-model `1ea3d08` multi-source case [42828135533](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42828135533) failed **0/1, zero skips**, after obtaining two cited sources: the first selected source-2 quote lacked the requested domain term. A source may have multiple quotes; `0448126` searches that source's actual citation set for the required term, retaining the exact source/nonempty/domain assertions. The failed log does not prove a qualifying alternative quote existed. [Original failure and selector rationale](evidence/live-multi-source-1ea3d08.json). Retest: [42839708011](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42839708011).

## Native PDF page assembly and explicit import-copy entry

The documents catalog now exposes real 1–3-file static PDF extraction/reordering/interleaved merging and native PDF export. Each file requires its own read approval; the exact page order is reviewed before a separate one-use assembly grant. Changing or clearing selection fences late App results. The new user-facing import-copy entry keeps the original picker entry and discloses the OS-created copy before selection; the system copy precedes the separate App read approval.

The final local core executes **284/284 assertions**, including actual raster Image XObjects/pixel comparisons, text/page order, repeated pages, fractional boxes, aggregate 200-page bounds, actual coordinated reads and cancellation races. A strict equality negative control rejects a valid fractional roundtrip with a 1.1368683772161603e-13-point difference; finite four-ULP comparison accepts it while meaningful geometry changes and NaN/Inf remain rejected. [Core evidence](evidence/pdf-assembly-core-local.json). Unchanged production App Session and FileDocument then pass **57 assertions per local Debug/Release configuration**, with actual held coordinated-read cancellation, stale-order refusal, immutable output and disk export/readback. [App evidence](evidence/pdf-assembly-app-local.json). These local results are not iOS UI passes or full Python tool parity.

The earlier DEBUG copy experiment at `e09db96`, [42828634934](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42828634934), completes **1/1, zero skips**, in 214.259 seconds within the unchanged 240-second allowance: one real native import callback, both approvals, complete two-page output and final audit. The old intro-query interval is 0.14 seconds in this run and summary-to-text is 1.87 seconds without the redundant top scroll; other AX stalls still occur, so this is not a controlled speed benchmark. [Bounded evidence](evidence/file-provider-import-copy-e09db96.json). The new user-copy and page-assembly UI methods have dedicated strict count/completion scopes and remain to be executed natively. The source inventory now contains **68 non-Live / 16 Live methods**; inventory is not execution.

## Completed workspace matrix and new Release build

The `faf7536` SE job [129905353706](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42838022703/job/129905353706) also completed **41/41, zero skips**, with 41 unique starts and completions. [SE evidence](evidence/workspace-se-faf7536.json). The complete same-source workspace matrix is **122 passed / 1 failed / zero skipped**: all 108 native/hosted instances pass; UI is 14/15, retaining the current-runtime secure-field targeting failure. Its geometry-verified single-touch repair and unchanged real POST/cookie assertions are documented in [original failure evidence](evidence/browser-login-faf7536-current.json); new login matrix [42847884733](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42847884733) is pending.

Release source `80a1121`, [42843044229](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42843044229), successfully builds device code including the new PDF features: **build 45, minimum iOS 17.0, nine verified binaries**. [Build evidence](evidence/unsigned-device-80a1121.json). This artifact is unsigned and not installable; it does not establish XCTest, physical-device or TestFlight acceptance.

The same source's three native-matrix jobs failed earlier during portable test compilation: the raster assertion's compound expression exceeded the Swift type-checker's limit. Revision `74f7b71` uses an equivalent loop, retaining every RGB threshold and assertion; actual local PDFKit still passes **284/284**. [Original compiler errors and follow-up state](evidence/native-build-80a1121.json). Queued/in-progress scopes were cancelled and replaced with corrected-source runs; cancellation is not a functional verdict.

## Actual multi-source research stops with an unclassified error

The actual-model `0448126` retest [42839708011](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42839708011) failed **0/1, zero skips**, at the App's research-error check, before citation assertions. Its native transport probe separately failed with only a generic `HTTPChatModelError` category. [Bounded events](evidence/live-multi-source-0448126.json). No shared cause or authentication, quota, provider, transport, command or citation root cause is inferred. New fixed-category diagnostics expose only failure labels and page counts; they do not themselves fix or pass the workflow.

## Large workspace accepts permanent retirement; current login still fails

At `faf7536`, the Large variant of [42838022703](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42838022703/job/129905353654) passed **41/41, zero skips** on iPhone 16 Pro Max / iOS 18.5: 36 native/hosted and five UI methods, with 41 unique actual starts and completions. Retained loaded sessions and a never-materialized session both reject navigation after retirement. Selected cookies and late-added localStorage disappear while unrelated cookies remain. Login/cross-tab/relaunch/logout and site-clear/relaunch UI pass. The selected-site trace records old-page disposal at 25 ms, removal at 35 ms, verified refresh at 36 ms and replacement at 46 ms. [Exact evidence](evidence/workspace-large-faf7536.json). These durations are not a controlled performance benchmark.

The same run's current iOS 26.2 job failed its native login UI at secure-field hittability before typing the password; its remaining native/hosted and UI cases passed. Investigation and the SE variant remain pending. The Large result is not a matrix-wide pass.

## Large website-clear regression passed with refreshed records

At `c532fbe`, [42832418470](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42832418470) completed **40/40 workspace methods, zero skips** on iPhone 16 Pro Max / iOS 18.5: 35 native/hosted and five complete UI cases. The selected-site core case passed in 1.508 seconds; both old pages stopped by 29 ms, refreshed records were selected at 32 ms, removal completed at 47 ms, verified records published at 49 ms, and replacement occurred at 58 ms. Late-added localStorage was removed, unrelated cookies remained, and login/cross-tab/relaunch/logout/clear-after-relaunch UI all passed. [Exact methods and trace](evidence/workspace-large-c532fbe.json). This single run is not a controlled speed comparison and predates the permanent session-retirement patch. The later three-device workspace run is [42838022703](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42838022703).

## Actual-model profile recall and three-device memory UI follow-up

At `dabe9bf`, [42833548977](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42833548977) passed **1/1 actual-model profile UI, zero skips**, in 107.319 seconds. After saving a random preference and relaunching, the first foreground query returned that exact value. After disabling memory and relaunching again, a second query returned exactly `UNKNOWN`, while the saved profile remained. These are two completed foreground queries, not a claim about all background/provider HTTP requests. No keyboard introduction tap was observed, so the previous toolbar failure cause remains unproved. [Source and native event evidence](evidence/live-profile-dabe9bf.json).

The earlier `1ea3d08` three-device memory shard completed **22 passed / 8 failed / zero skipped**. Expanded history rows visibly existed but inherited the disclosure control identifier; three combined Profile cases and one SE Memory case exhausted their unchanged method allowances. SE also checked a Skills empty-state row before scrolling it into view. [Counts, missing completion events and fixture evidence](evidence/memory-ui-1ea3d08.json). Revision `faf7536` makes history rows independently accessible, separates long scenarios while retaining their assertions and 180/240-second limits, and reveals the compact empty state. Its **13-case/device** retest is [42838016543](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42838016543); those pending results are not passes.

## Retired browser sessions cannot reopen deleted-site documents

Source review found that stopped sessions retained after website deletion could still accept `manualNavigation`, after their WebKit delegates had been detached. Sessions now retire permanently before page disposal, including sessions whose WebView was never created; observations/navigation flags are cleared and later manual/model navigation is rejected. Browser and library views show the pending removal, and navigation controls stay disabled.

The exact production-source macOS comparison reproduced the missing guard at `a97a7f0` (**8/10**, both retirement assertions failed) and passed the candidate (**10/10**). Debug/Release App-logic typechecks also passed. [Bounded evidence](evidence/browser-session-retirement-local.json). No WKWebView was created in that local comparison; a new hosted regression and retained-loaded-session assertions require native acceptance.

## Exact iOS 17 core with profile and multi-source research

At `1ea3d08`, [42828238084](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42828238084) completed **163/163 native/hosted methods, zero skips**, on exact **17.0.1 / 21A342**, without the experimental test-daemon prelaunch. Actual method starts/completions are unique and agree with the result summary. The selected-site cookie case passed in 19.526 seconds. [Exact method and artifact evidence](evidence/ios17-core-1ea3d08.json). This revision includes the profile CR/LF fix and multi-source feature, but predates the refreshed website-deletion implementation; UI, live-service and physical-device acceptance remain separate.

## Private live runner and keyboard follow-up

The single-invocation iOS 17 MCP experiment at `87dca8a`, [42827099096](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42827099096), passed the native HA probe and App build, then the UI runner was killed before starting any of its three methods. The verifier rejected a one-item bootstrap failure against three expected methods. [Bounded bootstrap evidence](evidence/live-ha-87dca8a-ios17.json). No native lifecycle helper or model-tool UI acceptance is inferred. An opt-in prelaunch now reuses the existing release helper on the owned exact 17.0.1 simulator: one attempt, a shared 120-second budget, no kill/retry and no handshake claim. Seven wrapper tests passed; live retest is required.

At `1ea3d08`, actual-model profile [42828130700](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42828130700) still failed **0/1, zero skips**, before a model request: the actual sentence was typed correctly, but the keyboard toolbar readiness predicate exceeded five seconds. The test now handles only the exact native QuickPath introduction used by existing fixture keyboard flows, and records fixed native geometry/boolean diagnostics on a toolbar failure. This is a diagnostic hypothesis, not an established onboarding cause; the wait and all recall/master-switch assertions remain unchanged.

## Complete native matrix at 1ea3d08: SE/current passed; Large site deletion exceeded its bound

[42828114273](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42828114273) executed all seven native/hosted targets: **SE 163/163; current 163/163; Large 162/163; zero skips throughout**. The 14 new profile/multi-source methods passed on each device (**42/42**), including the CR/LF regression and actual encrypted App store. [Counts, unique method checks, runtime metadata and original removal timelines](evidence/native-matrix-1ea3d08.json).

Large's existing selected-site removal case failed its unchanged 30-second bound. Both pages stopped by 29 ms; the actual WebKit removal callback arrived at 50.042 seconds. The later callback and empty selected-record counts do not override the failed method or prove every downstream assertion. No iOS UI/live acceptance is inferred from native cases.

The follow-up stops pages, re-enumerates the selected site records, deletes their refreshed actual data types, then re-enumerates to verify removal before publishing completion or mounting a replacement view. Refresh requests before/during removal cannot overwrite the final list. The hosted case now also writes localStorage after the original confirmation snapshot and requires its absence afterward, while preserving the unrelated cookie and the 30-second bound. WebKit's [current upstream implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebsiteData/WebsiteDataStore.cpp) dispatches deletion work according to requested types; avoiding unused subsystems is a performance hypothesis, not a proven explanation for the installed iOS 18.5 build. Native retesting is required.

The fixture-diagnostic copier also now accepts the already-emitted `pagesDiscarded` phase and the new count-only phases; previously it rejected a complete trace at that phase. Four schema/privacy regression tests pass. No website names, cookie values or URLs are added to diagnostic files.

## Selected PDF UI avoids a redundant return to the beginning

The failed import-copy case's log places **42.98 seconds** between finding the static `skillExecution.intro` anchor and the next action in `scrollExecutionToTop()`. The anchor is never tapped. Its check now requires its entire frame inside the unobscured Form, while actual approval controls still require hittability. After inspecting the extraction summary, the test keeps that viewport to inspect the immediately following output and reads the actual label once for all existing exact marker/namespace assertions. The 240-second deadline, picker selection, both approvals and final audit are unchanged. Native retesting must establish any timing improvement; the lower-level cause of the delay is not established.

## Exact iOS 17 memory shard completed before the new profile feature

At `d464176`, [42819575642](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42819575642) passed the then-current **7/7 memory UI methods, zero skips** on exact **17.0.1 / 21A342**. This covers memory editing/persistence, procedure approval, skill import/revision/rollback and clearing while a reply is pending. The opt-in one-shot test-daemon prelaunch ran for 54.782 seconds without establishing a handshake; all seven actual XCTest methods subsequently completed. [Evidence](evidence/ios17-memory-prelaunch-d464176.json). The new three profile UI methods are absent from that revision and require separate acceptance.

## Profile newline regression and native-toolbar test correction

At `cdf10d1`, [42825863580](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42825863580) stopped in portable-core validation before iOS tests: the profile safety method expected `invalid_sentence` but an input was accepted. The three matrix jobs retained that failure. Profile validation now checks CR/LF UTF-16 code units explicitly, avoiding Swift's combined-CRLF Character matching, and covers add/replace/decode transaction boundaries. Local **199 state / 58 real LearningStore encryption assertions** passed. The later `1ea3d08` native matrix and exact 17.0.1 core accepted this fix; UI and actual-model acceptance remain separate.

The same source built the actual App for live profile [42825870498](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42825870498) and multi-source [42825876107](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42825876107). Each UI method failed **0/1, zero skips**, before its model request: the test tried to scroll the Form to reveal its keyboard toolbar (`profile.editor.done` / `multiResearch.keyboardDone`). Toolbar actions now require the actual control to be enabled, hittable and inside the App window, followed by one native tap; only Form rows use scrolling. Model, source, citation, persistence and deadline assertions remain unchanged. These failures are not model or feature acceptance passes.

## Native picker experiments preserve failed acceptance results

The fresh-peer current simulator at `d464176` [42819390644](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42819390644) still failed **0/1, zero skips** in actual UIKit open mode, with the same provider resolver errors and no App callback. Its newly created UUID was removed afterward. [Evidence](evidence/file-provider-fresh-d464176.json). A fresh simulator alone did not resolve this observation.

The DEBUG import-copy experiment at `21c29d2` [42815645050](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42815645050) delivered one real native callback, then completed both separate App approvals, one read and one PDF extraction/result. The selected case nevertheless failed **0/1, zero skips** at its unchanged 240-second method deadline while revealing result text, followed by a termination failure. Post-timeout observations do not count as a pass. [Complete bounded timeline](evidence/file-provider-import-copy-21c29d2.json). This isolated observation neither proves intermittent failures eliminated nor changes the production picker; OS import-copy may copy/read before the App's read approval.

The open-mode resolver trace matches the coordinated source URL, App document container and file inode at observed checkpoints; DocumentManager's selection is distinct from an App callback. [Trace](evidence/file-provider-resolver-chain-ca3e72a.json). Migration also appeared before the successful copy callback; SE artifacts lack the daemon logs needed for a matching comparison. [Migration comparison](evidence/file-provider-migration-comparison-d464-21c.json) does not establish migration as the cause.

## Exact iOS 17 live MCP launch handoff under investigation

At `da553bc`, [42816449809](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42816449809), real discovery/disconnect/reconnect and model refusal passed, while the approved two-tool case failed in setup before issuing a model/tool request: SpringBoard denied launch because the App was installing or uninstalling. The workflow had two XCTest invocations. The next experiment keeps all three methods in one invocation, observes native termination/Home/foreground states without launch retries, preserves strict count and zero-skip verification, and always removes its dedicated simulator. These states do not establish installer readiness; native retest is required. [Exact 17.0.1 runtime and method evidence](evidence/live-ha-da553-ios17.json).

## Personal profile and multi-source research integration ready for native acceptance

Manual profiles preserve the pinned active/superseded semantics and use the real encrypted learning vault. Local **173 state assertions / 58 actual persistence assertions** passed; native hosted, three UI and actual-model recall/master-switch tests are added, with results pending. [Scope](USER_PROFILE.md).

Multi-source research adds 2–3 confirmed origins, isolated WebKit sessions, exact source receipts/citations, shared deadlines and one bounded JSON syntax correction. Local **74 core assertions / 18 real macOS WebKit assertions** passed. Five native core, three hosted, two UI and one real public-web/model case are added. [Source hashes and test boundaries](evidence/multi-source-local-02295ec.json). At that revision the source inventory owned **63 non-Live UI methods** and **16 Live UI methods**; later additions are counted above. These are source inventory counts, not executed passes.

## Exact iOS 17 full native/hosted core passed at 01d3646

[42815317834](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42815317834) completed **149/149 native/hosted methods, zero skips** on iOS 17.0.1 ARM64 without the experimental daemon prelaunch. Actual shared-cookie enumeration/deletion passed in 5.092 seconds, retaining the original 15-second enumeration bound; transcript transport cancellation/timeout also passed. No failure-only cookie diagnostic fired, so the earlier intermittent enumeration cause remains unproved. [Exact evidence](evidence/ios17-core-01d3646.json). This source predates the new profile/multi-source features.

## Transcript matrix preserved actual native provider failures

The `9a53e61` three-device transcript scope completed **81/84, zero skips**: all **75/75 native/hosted methods** passed, while UI was **6/9**. SE and Large failed the refusal case before reaching refusal because the selected TXT could not be resolved by FileProvider. Current failed the approved-selection case while its refusal case passed. [Native events, source identities and bounded evidence](evidence/transcript-native-9a53e61.json). Correct-source clicks and successful other cases do not turn these failures into passes; approval/runtime checks remain unchanged.


## Actual-model transcript timestamp and wording quality regression

The revised prompt preserves source time markers, keeps chapter titles separate, and avoids turning permission into a maximum/minimum/obligation. The evidence validator is unchanged. Two fixed sources (847 bytes with timecodes; 817 without) completed **10/10 actual HTTP model results, 24 calls** on local macOS. Full-prose review confirmed quantities, permission, principal topics/order and absence of invented times; quotations and transcript sections reproduce the complete respective original source in order. Earlier missing timestamps and unsupported maximum wording remain recorded in [the bounded before/after evidence](evidence/transcript-quality-wording-v2.json). This is a ten-result semantic review over fixed sources, not a universal quality guarantee or a substitute for native Files UI acceptance.


## Exact iOS 17 complete selected document UI passed

At `2fce6cf`, [42805689497](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42805689497) completed **8/8 UI, zero skips** on iOS 17.0.1 ARM64. The actual native picker, both PDF approvals and extraction, refusal/cancellation, export to a chosen local folder, export cancellation/recovery, and dedicated worker settings/relaunch all passed. [Exact method evidence](evidence/ios17-documents-2fce6cf.json). This does not exercise an authenticated production worker, later UIKit experiment arms or a physical iPhone.

## Opt-in iOS 17 test-daemon prelaunch executed the selected smoke case

At `01d3646`, [42815313693](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42815313693) passed the unchanged section-reachability UI **1/1, zero skips** on exact iOS 17.0.1. The one-shot daemon prelaunch took 1.071 seconds; subsequent XCTest completed. [Evidence](evidence/ios17-prelaunch-01d3646.json). A live process alone is not handshake evidence, and this single result does not establish causality or repair every previous bootstrap failure. The later seven-case memory shard passed in its separate opt-in experiment above; default execution remains unchanged.


## Complete audited HA live acceptance passed on iOS 18.5

Source `2390926`, [42813278810](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42813278810), passed native read-only HA acceptance and **3/3 actual App UI, zero skips**. Discovery/disconnect/reconnect passed; the model selected two exact approved read-only tools, received both actual results and produced the required answer in **3 model calls**, with no correction or tool error. Refusal preserved the draft. [Fixed evidence](evidence/live-ha-2390926-ios18.json). The earlier provider HTTP rejection remains in the record; this successful run does not identify its cause or cover physical actuation.


## iOS 26 browser workspace full selected scope passed

At `347971e`, current iPhone 17 / iOS 26.2 [42803804104](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42803804104) passed **33/33, zero skips**: 28 native/hosted plus five complete UI cases. This includes actual login, cross-tab cookies, relaunch and logout, site-record clearing that stays cleared after relaunch, bookmarks/history, manual JavaScript dialogs and independent tabs. [Exact summary](evidence/workspace-current-347971e.json). Later DOM/skill changes need their own regression; the earlier SE 31/31 and this current result are revision-specific.


## Native Files through complete actual-model transcript passed

Source `9a53e61`, iOS 18.5 [42814220474](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42814220474), passed **1/1 App UI, zero skips**, 171.469 seconds. The system Files picker delivered the selected text file, explicit read/model-destination approvals completed, and the actual model made **4 requests / 3 range reads**, covering all **18,355 bytes** and returning one verified result. No schema correction was needed; exact citations and absence of automatic skill/draft creation were checked. [Bounded native evidence](evidence/live-file-transcript-9a53e61.json). This closes that previously failed workflow at this revision/runtime, while other provider variants and later timestamp-style changes remain separate.


## Five transcript formats completed on iOS 18.5 after bounded repair

Source `9a53e61`, [42814211141](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42814211141), passed **5/5 actual-model native formats, zero skips** over the fixed 847-byte source. Summary, chapters, quotations and article each used two calls without correction. Transcript used one syntax correction and three calls. All formats read the full snapshot and verified exact quotations; total model requests/responses were **11/11**. This establishes the bounded repair in a real response, not native Files UI or independent semantic-quality acceptance. [Per-format evidence](evidence/transcript-formats-9a53e61-ios18.json).

The matching exact iOS **17.0.1** run [42814216073](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42814216073) also passed **5/5, zero skips**: quotations and article each used one syntax correction; the other formats needed none. Total requests/responses were **12/12**, with all 847 bytes covered and citations verified. [iOS 17 per-format evidence](evidence/transcript-formats-9a53e61-ios17.json).

A separate one-shot macOS combined-model/HA diagnostic at the same source also passed: actual server catalog, exact approved two-tool calls, actual results and expected final answer; **3 model calls, 2 tool results, zero corrections/errors**. It is explicitly not iOS/UI evidence and does not establish the cause of the earlier provider rejection. [Native local evidence](evidence/live-ha-local-9a53e61.json).


## Exact iOS 17 real-model HA conversation passed; manual disconnect remains under repair

At `23b47f4`, [42808230313](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42808230313) passed **2/2 actual-model HA App UI, zero skips** on iOS 17.0.1. The model proposed the exact audited arithmetic and floor/area calls, received two successful results, and produced the required answer in three model calls with no format correction. The separate refusal case preserved the draft. [Fixed-count evidence](evidence/live-ha-23b47f4-ios17.json).

The workflow still failed its discovery case: initial discovery, background disconnect and reconnect completed, but the second manual disconnect tap left the connected state. The old helper checked only `isHittable`, not the unobscured List viewport. The revised test uses the existing full-visibility geometry, performs one native tap, waits at most five seconds for the actual disconnected state, and requires both catalog counts to disappear. Obstruction is a candidate, not a proven root cause; native retest remains required.


## UIKit open-in-place reproduced the native picker failure

At `ca3e72a`, current iOS 26.2 [42806373840](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42806373840) executed the explicit UIKit open-in-place case and failed **0/1, zero skips**. The App independently observed actual picker mode `open`, then the exact synthetic PDF was tapped. FileProvider reported `-1005` with resolver `-1012`; no App importer callback arrived and neither App approval was reached. Fixture identity/hash matched before and after, which does not prove uninterrupted availability at the failure instant. [Bounded evidence](evidence/file-provider-uikit-ca3e72a.json).

A separate DEBUG-only import-copy arm now uses the system's `asCopy:true` with the same actual returned URL, one-file check, two App approvals and exact PDF text assertions. Its test explicitly acknowledges that the OS may copy/read before the App read approval. Production/default remains SwiftUI. Local DEBUG **40** / Release **36** checks and iOS syntax parse passed; the actual import-copy case subsequently delivered the file but failed its result-inspection deadline, as recorded above. No picker repair is claimed from compilation or a changed test entry point.


## iOS 17 method failures separated from runner bootstrap failures

The newer core run `2fce6cf` executed **144 methods: 142 passed, 2 failed**. One was the transcript transport-cancellation acknowledgement repaired in `9a53e61`; the other did not find the expected synthetic Cookie record before deletion. It does not prove `removeData` failed. The new observation preserves the original 15-second limit and all deletion assertions, distinguishing a missing publication from returned names/types that fail the predicate.

The same-source skills group executed **10 UI: 9 passed, 1 failed**. All three transcript UI cases passed. Only the original-Python availability text assertion was stale; `9a53e61` now checks the actual requirement for a separate service, no local Python, available native PDF extraction and incomplete original-tool support.

Workspace `347971e`, memory `32f4ecb` and learning `2fce6cf` each booted but executed **zero methods** before runner bootstrap SIGKILL. Preserved old startup diagnostics identify a RunningBoard initialization assertion expiry and a 106.6-second test daemon launch delay; the underlying system delay remains unknown. An **opt-in, default-off** one-shot daemon prelaunch experiment has a shared 120-second budget, no restart/retry and no claim that process liveness proves XCTest readiness. The next experiment must execute the unchanged native startup case. [Bounded reports and exact run references](evidence/ios17-bootstrap-and-core-2fce6cf.json).


## Transcript bounded command repair ready for native and live regression

The runtime now permits one fixed schema correction across the entire task, within the original **24 calls / 180 seconds**. A second invalid command, invalid byte range, incomplete coverage or unverifiable quote stops without executing the rejected operation. Actual HTTP tests cover cancellation acknowledgements before session teardown, context revocation, cumulative deadlines, no unknown tool/path execution and preservation of previous valid reads. All **14 local HTTP/core groups** passed, with DEBUG/Release UI fixture guards and warnings-as-errors compilation of the Session/probe. Native and actual-model runs on the repair are still required.

The original `e493842` native transcript matrix is retained: current and SE each **17/19**, large **16/19**, zero skips. All three hit the too-early transport-cancellation assertion; native selected-file handoff also failed on each variant, and large additionally showed an expensive AX collection query. The test repairs wait for actual cancellation acknowledgement before teardown and use the specific live first-match query. They do not inject a selected URL, retry a native file tap or waive either approval.

The standard simulator workflow now exposes the same eight non-Live UI shards as iOS 17, plus a complete native/hosted scope. Its inventory verifies all **57 current non-Live UI methods** have exactly one owner; this avoids treating a long monolithic timeout or omitted class as acceptance. It does not itself execute those cases.


## Actual HA discovery passed; model request rejected before tool execution

At `23b47f4`, iOS 18.5 [42808237063](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42808237063) passed native HA initialization, catalog discovery, audited read-only operations, explicit business-error handling and local rejection of unapproved mutation. Native App discovery/disconnect/reconnect passed **1/1, zero skips**. The actual-model conversation cases failed **0/2**. The two-tool case recorded its first model HTTP request rejected with **zero proposed/attempted/completed MCP operations**; the older refusal test did not preserve a terminal category. [Fixed-category evidence](evidence/live-ha-23b47f4.json).

`2390926` separates authentication rejection, rate limiting, provider server errors and other request rejection into fixed enum categories, without retaining response bodies or retrying a tool. The refusal UI now waits for an actual proposal or terminal App state and prints only App-owned counters/categories. All 15 local MCP groups / 498 checks passed, including transport, exact approvals, single schema correction, deadline/cancellation and no replay after model failure. A new actual HA run is required; diagnostics alone are not a model-service repair.


## Corrected settings matrix and iOS 17 browser interaction passed

At `2fce6cf`, [42805681299](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42805681299) passed **10/10 on each of SE/18.5, large/18.5 and current/26.2**, zero failures/skips. This includes eight native appearance cases, actual appearance/persistence UI and dedicated script-service settings save/remove/relaunch with zero automatic PDF reads. The corrected fixed-header selector reached the real settings form. This does not establish deployed worker connectivity. [Exact summaries](evidence/settings-matrix-2fce6cf.json).

At `32f4ecb`, exact iOS 17.0.1 [42805244364](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42805244364) passed **5/5 browser UI**, zero failures/skips: public-page navigation/interaction plus actual native upload and cancellation. The earlier missing native input label was repaired without changing the input/refusal/effect assertions. Other iOS 17 groups remain separate. [Exact summary](evidence/ios17-browser-32f4ecb.json).


## Transcript model failures retained for repair

At `4108325`, actual native model probes over fixed 847-byte source passed **4/5 formats on iOS 18.5** ([42806954467](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42806954467)) and **3/5 on iOS 17.0.1** ([42806963315](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42806963315)). Every failed format returned `invalidCommand` on its first model response, before reading any source; successful formats read all bytes and verified citations in two real calls. These are genuine failures, not missing-runtime/skip outcomes. A bounded schema correction is being implemented without broadening accepted tools or arguments. [Fixed-code evidence](evidence/transcript-formats-4108325.json).

The longer native-file real-model UI case at `e493842` [42802753665](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42802753665) failed **0/1**, 130.045 seconds, at the final audit's expected completed-result count. This run passed native selection/read steps but did not accept a completed model result. Its older test does not expose a fixed terminal failure category, so the short-source formatting failures cannot be assumed to be its cause. [Retained UI evidence](evidence/live-file-transcript-e493842.json).


## Public webpage to real-model transcript verified (`08fec36`)

[42802827631](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42802827631) passed **1/1 App UI, zero skips**, 76.495 seconds on iPhone 16 Pro Max / iOS 18.5. It loaded IANA through real WebKit, captured the page text, reviewed the source URL, approved the model destination, and required full snapshot coverage plus byte-verified model quotations. No skill/draft was automatically created. This covers the initial DOM implementation; the subsequent accessible-tree/omission fixes have separate local WebKit evidence and await hosted regression. [Bounded live evidence](evidence/live-browser-transcript-08fec36.json).


## Native iOS 26 login repair verified

At `8ffc4d6`, [42802237758](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42802237758) passed **1/1, zero skips**, 136.610 seconds on iPhone 17 / iOS 26.2. The native keyboard delivered the exact synthetic username; the real local HTTP form authenticated, cookies were used across tabs and App relaunch, and logout revoked access. This validates the specific native workflow, not arbitrary third-party identity providers. [Evidence](evidence/login-current-8ffc4d6.json).


## Settings matrix `2055c30`: 9/10 per device, repair submitted

[42800167438](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42800167438) ran the eight native appearance runtime cases plus two UI cases on SE/18.5, large/18.5 and current/26.2. Each variant passed **9/10, zero skips**: all native cases and actual manual appearance/persistence UI passed. Worker settings stopped before opening its form because a fixed Skills segment was incorrectly checked against the scrollable Form viewport. `2fce6cf` uses direct native readiness/tap for that fixed header and verifies its selected state; settings save/remove/relaunch and zero-read assertions remain unchanged. The corrected matrix is [42805681299](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42805681299), pending. [Retained evidence](evidence/settings-matrix-2055c30.json).


## Exact iOS 17.0.1 first full shard attempt (`6d480d8`)

All 51 non-Live UI methods were assigned; the actual run outcomes are below.
Zero-method runner failures are **unexecuted**, not functional passes or skips.

| Group | Passed | Failed methods | Not executed | Evidence |
|---|---:|---:|---:|---|
| core | 121 | 0 | 0 | [42797718070](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42797718070) |
| ui-documents | 7 | 0 | 0 | [42797731238](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42797731238) |
| ui-mcp | 5 | 0 | 0 | [42797777474](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42797777474), fixture conversation UI, not live HA |
| ui-workspace | 2 | 3 | 0 | Two native confirmation selector mismatches; QuickPath readiness remains unresolved |
| ui-browser | 3 | 2 | 0 | Native upload/cancel and approved form interaction passed; two unchanged-input checks used a missing iOS 17 field label |
| ui-startup | 0 | 0 | 12 | Runner killed before any method began |
| ui-memory | 0 | 0 | 7 | Runtime inventory timed out before simulator boot |
| ui-skills | 0 | 0 | 7 | Runner killed before any method began |
| ui-learning | 0 | 0 | 3 | Runner killed before any method began |

[First four diagnoses](evidence/ios17-first-shards-6d480d8.json), [skills/learning runner evidence](evidence/ios17-runner-skills-learning-6d480d8.json), and [MCP completion report](evidence/ios17-mcp-6d480d8.json) preserve the distinction. Three failed runner bundles are being inspected separately without rerunning their tests; new runs export diagnostics directly. Subsequent UI inventory includes new settings/transcript cases and must be validated against its own revision.


## 2026-11-10: real-model appearance flow

Source `2055c30`, [live run 42800157677](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42800157677), passed **1/1 App UI, zero skips**, 104.585 seconds on iPhone 16 Pro Max / iOS 18.5. The actual configured model listed settings, changed appearance to dark after explicit permission, and the test checked SwiftUI's actual color scheme, persistence after relaunch, and permission revocation. The seven separate native live transport/memory/skill-learning requests also passed; learning there uses explicitly synthetic executor evidence. [Bounded evidence](evidence/live-appearance-2055c30.json). This does not establish complete original settings-tool or physical-device parity.


## 2026-11-10: device build and iOS 17 confirmation selectors

Source `08fec36` [unsigned-device run 42802907455](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42802907455) passed on Xcode 26.2 / iPhoneOS SDK 26.2, build 31. All nine device binaries retain minimum iOS 17.0; native Documents configuration, absent ATS exceptions and required-reason manifest were verified. This includes the initial transcript integration but not later DOM fixes. It is an unsigned, **noninstallable** build, not a signed release or physical-device result. [Report](evidence/unsigned-device-08fec36.json).

The `6d480d8` iOS 17 workspace failures exposed the website/history confirmation as an accessibility `Other`, whereas iOS 26 exposes `Sheet`. The selector correction keeps the exact dialog title, destructive button identifier/label, cookie-revocation/relaunch checks and original deadlines. It accepts those observed native container types; corrected UI execution remains pending.


## 2026-11-10: additional actual-model and exact iOS 17 results

At `6d480d8`, real-model skill authoring [42797710686](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42797710686) passed **1/1 UI, zero skips** in 106.394 seconds. The configured model used actual catalog search/read and prepared a draft; the UI required explicit approval and verified the exact encrypted Markdown after relaunch. [Bounded evidence](evidence/live-authoring-6d480d8.json).

On exact iOS **17.0.1 (21A342)**, ARM macOS 15.8.2/Xcode 16.4, [core 42797718070](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42797718070) passed **121/121**, and [documents 42797731238](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42797731238) passed **7/7 UI**, both zero skips. Documents includes native direct/coordinated PDF selection, both approval refusals, picker cancellation, native export save and export cancellation. These results apply to `6d480d8`; newer settings/transcript changes need separate regression. Other iOS 17 groups have failures or remain running, so this is not complete runtime/physical-device acceptance. [Exact reports](evidence/ios17-core-documents-6d480d8.json).

The iOS 26 workspace failure at `68c49a6` was localized to missing native username input before any authenticated request: all 119 username accessibility snapshots were empty, with a Zhuyin keyboard in the recording. A focused test repair selects the actual English keyboard and asserts exact synthetic username input before moving focus and before submission. It preserves HTTP/cookie/relaunch/logout assertions and does not retry typing. Native retest is pending; why XCTest dropped that insertion is not established. [Diagnosis](evidence/login-input-68c49a6.json).


## iOS 17 ARM environment comparison

At `b5083b7`, both GitHub ARM runs passed the real App UI case
`testEverySectionIsReachableAndPhoneControlIsExcluded`, with zero failures/skips:
[17.0.1 / 42793955136](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42793955136)
in 64.648 seconds and
[17.5 / 42793983325](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42793983325)
in 47.721 seconds. Both used Xcode 16.4 on ARM macOS 15.8.2; actual runtime builds
were 21A342 and 21F79. Boot reached its successful terminal state and the UI runner
executed the selected case. The reports deliberately retain `runtime_tested:false`
because startup-smoke is not full acceptance. Physical devices were not used.

The [retained comparison](evidence/ios17-arm-startup-b5083b7.json) includes original
reports and log hashes. This establishes a working test environment for subsequent
functional shards. It does not prove architecture alone caused the earlier Intel
boot/AX failures, since the host macOS image also changed, and does not replace
the failed runs below.

## Browser workspace / files / PDF increment - partial acceptance

Latest completed simulator evidence (passed test cases / selected cases, not assertion counts):

| Workflow / source | iPhone SE, 18.5 | iPhone 16 Pro Max, 18.5 | iPhone 17, 26.2 |
| --- | --- | --- | --- |
| [Workspace 42763765491](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42763765491), `1747c20` | Native/hosted 26/26; UI 3/5 | Native/hosted 25/26; UI 3/5 | Native/hosted 26/26; UI 3/5 |
| [Workspace 42769973948](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42769973948), `0df511b` | Native/hosted 26/26; UI 4/5 | Native/hosted 26/26; UI 5/5 | Native/hosted 26/26; UI 5/5 |
| [Files 42762605111](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42762605111), `776f5f9` | Native/hosted 40/40; UI 5/8 | Native/hosted 40/40; UI 8/8 | Native/hosted 40/40; UI 6/8 |
| [Files 42769116674](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42769116674), `1b0f3d8` | Native/hosted 44/45; UI 7/8 | Native/hosted 45/45; UI 8/8 | Native/hosted 45/45; UI 6/8 |
| [Parity 42762628864](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42762628864), `776f5f9` | Native/hosted 94/94; UI 18/21 | Native/hosted 94/94; UI 21/21 | Native/hosted 94/94; UI 21/21 |
| [Learning 42769122118](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42769122118), `1b0f3d8` | Native 39/39; UI 9/10 | Native 39/39; UI 9/10 | Native 39/39; UI 10/10 |
| [Manual authoring 42772009461](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42772009461), `5d85da4` | Native 5/5; UI 3/4 | Native 5/5; UI 4/4 | Native 5/5; UI 3/4 |
| [SE files 42773301406](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42773301406), `e2b7de9` | Native/hosted 45/45; UI 6/8 | Not selected | Not selected |
| [SE workspace 42778341962](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42778341962), `e941709` | Native/hosted 26/26; UI 3/5 | Not selected | Not selected |
| [Large browser 42776190893](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42776190893), `8f89d9e` | Not selected | Native 29/30; UI 3/3 | Not selected |
| Manual authoring `616178d`: [SE 42779742743](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42779742743), [current 42779748377](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42779748377) | Native 5/5; UI 4/4 | Not selected | Native 5/5; UI 4/4 |
| [SE browser 42779755190](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42779755190), `616178d` | Native 29/30; UI 3/3 | Not selected | Not selected |
| [Current file-picker 42780906250](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42780906250), `7c7a0cb` | Not selected | Not selected | Native 5/5; UI 3/3 |
| [SE file-picker 42782850081](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42782850081), `d1fb868` | Native 5/5; UI 3/3 | Not selected | Not selected |
| Core `2dd7b69`: [SE 42784364067](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42784364067), [current 42784372596](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42784372596) | Native/hosted 34/34 | Not selected | Native/hosted 34/34 |
| [SE login 42784628988](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42784628988), `5dd9047` | UI 1/1 | Not selected | Not selected |
| PDF export `afa1a72`: [SE 42785936385](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42785936385), [current 42785943219](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42785943219) | UI 1/2 | Not selected | UI 0/2 |
| [Current export 42789964607](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42789964607), `645036e` | Not selected | Not selected | UI 1/2 |
| Workspace `68c49a6`: [SE 42795218559](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42795218559), [current 42795228599](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42795228599) | Native/hosted 26/26; UI 5/5 | Not selected | Native/hosted 26/26; UI 4/5 |

`68c49a6` waits for actual website-data removal before publishing/mounting the
replacement tab. The hosted regression now mounts each replacement immediately,
as the real SwiftUI view does. SE passed all 31 cases with zero skips, including
actual form login, shared cookies, relaunch, logout and per-site data removal
with HTTP denial and persistence after relaunch. Its clear-site UI case took
137.061 seconds; [case identities and log hashes](evidence/workspace-se-68c49a6.json)
are retained. Current iOS passed the website-data case and every hosted check;
its separate login case failed at the post-form authenticated-page assertion
(`BrowserLoginUITests.swift:419`, 117.555 seconds). It is recorded as 30/31,
not a full workspace pass; the login failure remains under investigation.

The `776f5f9` and `1747c20` variants passed 98 portable cases. The completed
`1b0f3d8` files variants passed 103, including the five new authoring
bridge cases, plus all 12 original-worker cases with real Swift HTTP integration. Each files variant also passed the 12 original-script
worker cases, including the real Swift HTTP client. No selected test was skipped in these three scoped matrices. A timed-out
case is a failure even when XCTest restarts and later prints a passing suite:
`SkillExecutionTests.testCancellationAndUploadGating` exceeded its four-minute
allowance in the older parity SE (`e1024aa`) and files large (`4dbbddb`) runs.
The older parity failure remains in the historical records below; the replacement files run
`776f5f9` passed cancellation on all three native simulators.

- Files `776f5f9`: all selected native/hosted cases passed, including actual viewport
  scrolling, raw-address rejection and persistent per-site cookie removal.
  Large passed all eight UI cases. SE failed three PDF status-row searches after
  the bounded-scroll helper exhausted its short drags. Current passed both native
  export cases but failed the longer PDF status search and an interrupted AX
  lookup during upload cancellation. Actual extraction/result evidence is retained;
  those failed UI cases are not counted as passes.
- Workspace `1747c20`: tabs, bookmark/history/relaunch and manual query/dialog UI now
  passed on all three variants. The two login/clear-site UI cases still failed:
  keyboard tutorial geometry, XCTest idle-wait timeout and locating the native
  clear confirmation remain under investigation. Large also exceeded the hosted
  deletion wait: pages stopped within 35 ms, WebKit completed removal at 23.066 s,
  and the selected website records became zero, after the old 15-second assertion.
  This is not a complete UI cookie-revocation/relaunch pass. The earlier `e1024aa`
  large login/relaunch/logout success remains separate historical evidence.
- Parity: the newer large run passed all 21 UI cases. SE passed 18/21; the
  remaining failures concern resolving a visible website-note field, a static
  learning-status row extending 3.5pt below the viewport, and missing characters
  during one synthesized 60-character/second editor input. Exact text and
  persistence assertions remain required. The current-runtime variant passed all 94 native/hosted and 21 UI cases.
- [Release 42758873943](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42758873943)
  on `0092fc8` passed: nine device binaries, App minimum OS 17.0, SDK 26.2, native
  Documents flags, absent Release ATS key and packaged required-reason entries
  verified. Still unsigned/not installable, no runtime or distribution claim.
- [Live model 42751407713](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42751407713)
  on `e1024aa`: seven actual native model requests across transport/memory/skill
  probes and all seven live UI cases passed, zero failures/skips. Browser cases
  cover approved DOM navigation, public-page research, and five-page learning
  through approval/relaunch. The native skill-judge probe uses a synthetic
  trajectory, so it is not counted as live browser execution.

The first full iOS 17 runs use `d160a24`:
[17.5 42748380772](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42748380772)
completed with native/hosted 106 passed/one failed (two assertions), and UI 31
passed/15 failed/ten live-service skips.
[17.0.1 42748375007](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42748375007)
booted and recorded native 96 passed/one failed and UI 26 passed/15 failed/ten
skips, then reached the old 55-minute limit before finishing all UI and hosted
cases. Both actually executed App code, and neither is a full pass.
`1153d5a`/`0092fc8` fix Foundation discarding malformed ports by checking the
original address before normalization; 1,034 local direct Swift checks passed.
The new native and hosted raw-address regression cases passed all three files
variants on `776f5f9` and in the successful iOS 17.0.1 core run on `1b0f3d8`.

Full reruns on `0092fc8` stopped before App tests:
[17.0.1 42758764668](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42758764668)
and [17.5 42758809838](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42758809838).
17.0.1 boot diagnostics ended with `Data Migration Failed`; 17.5 reached
`Finished`. In both runs the subsequent optional device inventory timed out and
masked the boot outcome. Neither run compiled or tested the App. The runner now
records boot success/failure before inventory, treats inventory failure only as
missing diagnostics, and preserves the primary failure through cleanup. It does
not retry boot or substitute another runtime.

Test-only repairs on `776f5f9` ran in
[files 42762605111](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42762605111)
and [parity 42762628864](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42762628864).
They recognize the native export confirmation/ancestor route, preserve all result
and cancellation assertions, observe a single scroll dispatch across rendering
turns, and use bounded native scrolling for virtualized learning controls.
Cancellation spindumps located the stall after gate release in an unnecessary
PDFKit call inside the simulated remote adapter. The adapter now returns a valid
fixed response; positive-control and early-release cases ensure cancellation is
not merely hiding an invalid response. Actual PDFKit extraction and the original
Python worker remain covered separately. Large-device page-load delay remains
unexplained; deadline diagnostics were improved without changing the assertion.

The `776f5f9` files large variant completed successfully: 98 portable cases,
12 original-worker cases, 40 selected native/hosted cases and eight UI cases all
passed, zero selected skips. Both actual PDF export cases passed; the previously
timed-out cancellation case passed in 0.067 seconds in native XCTest. The native
PDFKit extraction remains a separate passing case. This also covers the hosted
persistent-cookie removal check, but does not substitute for the separate native
login/clear-site UI flow. SE completed with 40/40 native/hosted cases and 5/8 UI cases: three PDF UI cases failed to reveal a virtualized control using the new bounded-scroll helper. This is under investigation and is not counted as a pass. The current-runtime variant completed with 40/40 native/hosted cases and 6/8 UI: PDF export/save and export/cancel passed, the longer PDF-result case hit the same status-row search limit, and native upload cancellation failed on an interrupted remote AX lookup. Both remaining failures are under investigation.

The `776f5f9` parity large variant also completed successfully: 98 portable, 94 selected native/hosted and 21 UI cases passed, with no selected skips. SE completed with 94/94 native/hosted and 18/21 UI. Current completed with 94/94 native/hosted and 21/21 UI, zero skips. The formerly delayed local browser-load case passed in this run; its earlier intermittent cause is not claimed resolved.

Candidate UI-driver repairs on `41c589e` retain the operation and exact-value
assertions. Unknown virtualized rows are searched in overlapping half-viewports,
then corrected with short gestures. The file input is tapped once in its visible
leading button area; source-menu lookup is scoped to native containers. Memory
replacement observes each native character before sending the next, without
retrying or repairing text. This does not establish the root cause of the earlier
fast-input loss or prove product typing reliability at every speed. Browser learning
uses read-only visibility for a static label and resolves native field existence
before hittability. The `1b0f3d8` results are recorded above; that revision also fixes the authoring UI test
property colliding with XCTestCase.name. The original `41c589e` runs were
cancelled/replaced because that known test-target compilation error also affects
focused scopes. Replacement runs:
- [Files 42769116674](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42769116674), all three variants.
- [Learning 42769122118](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42769122118), all three variants.

The `1b0f3d8` files SE result is 51/53 selected native/hosted/UI cases;
large is 53/53, both with zero skips. SE export/save, full PDF extraction and both
native upload cases now pass. Export/cancel instead failed at initial navigation:
two CollectionViews became one, invalidating a cached index-1 query before file
selection. `5d85da4` binds containers by accessibility identity, checks cached
validity and reuses one snapshot's geometry; it preserves the gesture budget and
all outcome assertions. SE also hit the older 15-second hosted deletion deadline,
which `0df511b` already changes to a bounded 30 seconds. These fixes require native
reruns; large success does not retroactively pass SE. Targeted SE
[files 42773301406](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42773301406)
on `e2b7de9` includes both repairs. CI concurrency now separates effective device
variants, allowing this targeted run without cancelling the older full matrix.

The targeted `e2b7de9` SE files result is 51/53, zero skips. All 45 native/hosted
cases passed; six of eight UI cases passed, including full PDF extraction and
export cancellation. The older upload readiness queries failed before the native
picker opened, and export/save exceeded its 240-second allowance while reopening
the exporter to verify saved output. The stalled remote process is the system
DocumentManager service; a later spindump was collected after the earlier stall
recovered, so it does not establish the cause. No result or readback assertion was
removed and no deadline was increased.

The `e941709` SE workspace result is 29/31, zero skips. All 26 native/hosted cases
and three workspace UI cases passed, but the login case failed its QuickPath
tutorial readiness check and site clearing exceeded the shared 60-second wait.
The blank-page completion preceded removal and AX remained responsive; existing
evidence does not prove when the old WebView was detached/released. The wait
change alone is not a fix, and complete SE cookie-revocation/relaunch remains open.

The `1b0f3d8` current files variant finished 51/53, zero skips: native/hosted
45/45 and UI 6/8. Actual upload and both export cases passed. Upload cancellation
failed the bounded native-picker readiness check. Full PDF selection tapped the
correct enabled thumbnail, but the system logged `NSFileProviderErrorDomain -1005`
(file does not exist), could not resolve its bookmark, and returned an empty
selection before App import/extraction. This is not evidence of an ignored tap;
the artifact cannot prove the fixture's filesystem state after the error. No
production fix is claimed. `e7a0f70` removes redundant source-menu accessibility
queries during the same 45-second upload-picker wait; [current file-picker
42775938595](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42775938595)
compared both upload cases and the unchanged full-PDF flow. It completed 7/8:
native 5/5, upload UI 2/2 and full PDF UI 0/1, zero skips. At 08:03:05 UTC,
the provider again failed bookmark resolution with -1005 and an empty internal
delegate item array for a different fresh fixture. Upload readiness passed this
run; the earlier failure remains recorded. The PDF failure is reproducible, but
its filesystem cause is not yet established.

`7c7a0cb` adds a strictly DEBUG-gated creation baseline and post-test inventory
for only synthetic UUID PDF paths. It checks bounded regular-file bytes, title,
author, page count, hash and filesystem identity; rejects links and changed files;
and exports no PDF bytes or user paths. Actual local PDF/POSIX checks passed,
including abrupt process exit, replacement, missing/oversized files and Release
with no filesystem access. The evidence step runs even after export failure and
explicitly reports unavailable diagnostics. [Current diagnostic file-picker
42780906250](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42780906250)
repeats the same ordered selection cases to collect this missing observation.
Its passing result is recorded below; post-test presence alone cannot prove presence at the earlier
picker failure, and instrumentation is not a product fix.

Learning `1b0f3d8` passed all seven memory/race UI cases on every variant.
Large's only failure entered the browser address while it was still disabled
during asynchronous test-storage reset. `e7a0f70` waits for enabled/hittable state
before the same single input; [large browser 42776190893](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42776190893)
completed with all three browser-learning UI cases passing. Its full result is
32/33: a different native coordinated-file-read case exceeded four minutes;
29/30 native passed and no case was skipped. The native failure remains under
investigation and the overall job is not counted as passing. SE's only failure could not expose a website replay button below
the screen: recorded short drags began inside the search field and did not move
the list. `616178d` performs one conditional normal list swipe, retaining full
visibility, confirmation and actual replay assertions; [SE browser 42779755190](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42779755190)
passed all three UI cases; the separate native timeout and subsequent hosted-core
comparison are recorded below. The other two browser cases passed on both variants; current passed
all ten learning UI cases. No selected skips.

Manual authoring `5d85da4` passed its five native bridge tests everywhere and
all four large UI cases. SE passed create/read-update/cancel but failed exact
Markdown input before the invalid-tool check: the key burst lost/reordered
characters. Current passed create/read-update/invalid-tool but remained on Chat
after the first navigation tap in cancel. These failures do not demonstrate a
storage defect; keyboard delivery and missed navigation causes remain unproven.
`616178d` observes the first native character then each 16-character chunk without
repair/retry, and taps the visible navigation center once with an explicit
selection check. Full text, approvals, encryption and relaunch assertions remain;
the 240-second case allowance is unchanged. Targeted [SE authoring 42779742743](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42779742743)
and [current authoring 42779748377](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42779748377)
both passed as recorded below. These are manual authoring tests, not model-autonomous skill tools.

The `616178d` targeted SE authoring run completed **9/9**, zero failures/skips:
all five native bridge methods and four manual UI cases passed. Exact input,
approval/refusal and encrypted persistence/relaunch checks remain. UI durations
were 113.029 seconds (cancel), 122.101 (invalid tool), 198.132 (update/relaunch)
and 119.977 (create/relaunch), all within the unchanged 240-second allowance.
The same-source current authoring run also passed 9/9, zero failures/skips. Its update/relaunch case took 236.221 seconds, leaving 3.779 seconds within the unchanged 240-second allowance. This pass does not erase prior `5d85da4` failures.

The `7c7a0cb` current file-picker diagnostic run completed **8/8**, zero skips:
five native methods, both upload UI cases and the full PDF UI flow passed. Its
complete App log contains no provider -1005/-1012 or empty-delegate error. The
fixture creation baseline (08:29:42 UTC) and post-test inventory (08:32:32 UTC)
match at 8,477 bytes, identical device/inode, SHA-256 and modification time; the
native thumbnail tap occurred at 08:30:14 and selected filename appeared at
08:30:20. This successful run did not reproduce the failure and cannot establish
file presence during either earlier failed run. No copy-mode change is justified
by this result, and earlier provider failures remain unresolved.

`d1fb868` changes the product's PDF importer to show an actionable selection error
for empty/unexpected success arrays, without preparing a runtime or reading files.
A strictly gated DEBUG trace records callback delivery/count only. This fixes a
silent-result branch; it does not prove the provider error reaches that callback
or repair bookmark resolution. DEBUG/Release parse checks passed. [SE file-picker
42782850081](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42782850081)
and [unsigned Release 42782856252](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42782856252)
verify the new App code and both passed, as recorded below. The earlier `7c7a0cb` diagnostic run remains a
separate source checkpoint without this callback trace.

The `d1fb868` unsigned Release completed successfully: **build 19**, Xcode 26.2,
iphoneos SDK 26.2, minimum OS 17.0 and all nine binaries verified. Native Documents
flags, absent Release ATS key and required privacy-reason entries passed. It has
no verified distribution signature, no runtime acceptance or upload, and is not
installable. SE file-picker validation of this App revision passed 8/8, as recorded below.

`2dd7b69` makes the iOS Skills test target load the actual WoowAssistant host,
matching the existing WebKit integration target. The repeated unhosted native
failure stalled in `PDFDocument.init(data:)` after the coordinated bytes check;
its wait chain reaches SpringBoard, runningboardd and launchd. The host-context
explanation is a hypothesis, not a proven product fix. All PDF/coordination,
authorization, cancellation and authoring assertions remain unchanged. Real
XcodeGen output verified Debug/Release `TEST_HOST` and `BUNDLE_LOADER`; portable
macOS tests are unchanged. Controlled [SE core 42784364067](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42784364067)
and [current core 42784372596](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42784372596)
selected the same 34 memory/skills/persistence methods; both passed as recorded below.

`5dd9047` removes unnecessary hittability/geometry queries for static QuickPath
explanation text while still requiring the exact tutorial and an enabled,
hittable native Continue button. [SE login 42784628988](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42784628988)
selects the full login/cross-tab/relaunch/logout case with its original 420-second
allowance. It passed as recorded below; the separate website-removal deadline remains 60 seconds.

Final focused outcomes:

- SE browser `616178d`: UI 3/3 passed, including the real conditional list swipe,
  confirmation and replay result (153.035 seconds). Native 29/30 failed the same
  unhosted coordinated-read timeout; total 32/33, zero skips.
- SE file-picker `d1fb868`: 8/8 passed, zero skips. The actual importer callback
  logged `success count=1` at 08:41:16 UTC after the native thumbnail tap; the
  8,372-byte fixture retained its hash/device/inode/mtime at post-test inventory.
  No provider -1005/-1012 or empty-delegate error occurred. The empty-result guard
  was not exercised by this successful selection. Its unhosted coordinated-read
  case took 236.362 seconds, so that run alone does not resolve the timeout.
- Hosted core `2dd7b69`: both SE/current passed 34 distinct starts and passes,
  zero failures/skips (Skills 25, Memory 5, Persistence 4). Actual App-host linkage
  and `WoowAssistant` process diagnostics are present during coordinated reads,
  which took 0.089/0.091 seconds. Test directories and the PDF reader are unchanged
  from `d1fb868`; this supports the host-context correction without relaxing or
  replacing the actual PDF assertions. It is not an iOS 17 or UI acceptance run.
- SE login `5dd9047`: 1/1 passed in 101.936 seconds, zero skips. The native
  QuickPath prompt appeared and was dismissed; HTTP login, cross-tab cookies,
  relaunch persistence and post-logout protected-request refusal passed.
  Website removal remains a separate failure. Its prior trace shows blank-page
  completion at 162 ms, removal requested at 164 ms, Networking receipt and
  WebContent completion, but no Networking/database completion before App exit
  around 60 seconds. No successful post-clear cookie/HTTP/relaunch evidence or
  blocked Networking stack exists for that failure. Creating the new session
  before removal is an unproven hypothesis, not a confirmed cause.

`afa1a72` scopes export checks to the actual execution Form and native
DocumentManager navigation/file-list containers. The original SE stall occurred
in a global `intro.exists` lookup for 122.09 seconds after the first save; the
save-success status later passed before the second-open deadline. The change
retains 240 seconds, bounded scrolling, actual second opening/file-list evidence
and cancellation assertions. [SE export 42785936385](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42785936385)
and [current export 42785943219](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42785943219)
selected those two UI cases. SE finished 1/2, current 0/2, zero skips. SE
cancellation/retry passed in 174.486 seconds; save failed in 65.146 seconds at
the prerequisite selected-file callback, before PDF extraction/export. Current
cancellation failed at the same callback assertion in 111.974 seconds. Its save
case tapped the actual Save button at 114.73 seconds, then failed the bounded
execution-form first-row search after six swipes (141.364-second total). Each
post-save intro lookup took approximately 0.66–0.93 seconds, so the earlier
122-second lookup stall did not recur. Save-success status and reopening/file-list
verification were not reached. This does not establish why the row lookup failed,
whether the query change caused it, or whether file saving completed. No
provider/FileProvider cause or complete export fix is inferred.

The current save recording further shows the system exporter still covering the
App with a saving spinner at 117 seconds. At 129 seconds it remains visible and
has been dragged downward by the test gestures. The first row was not already
visible and missed by the scoped query. This establishes a test readiness gap:
the helper scrolled before export dismissal; the old blocked AX lookup was not a
valid substitute for waiting. `645036e` adds a maximum 30-second wait for the
actual native navigation container to disappear before any result-page gesture.
Failure stops the case; the existing 240-second total, exact saved/cancel status,
audit and reopen/file-list assertions remain unchanged. [Current export
42789964607](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42789964607)
finished **1/2**, zero skips: actual save, success status, audit, reopening the
native destination, finding the exact exported filename, and final cancellation
status all passed in 170.023 seconds. The separate cancellation/retry case failed
at the initial PDF importer callback after 88.157 seconds, before export. The
30-second dismissal gate and all prior acceptance assertions remain enabled.
This validates the test-readiness correction on this current-runtime save flow,
not a production saving fix or a resolution of the intermittent picker failure.
The workflow remains failed overall; SE was not selected for this rerun.
The actual dismissal was observed about 22 seconds after its first logged poll;
the first result-page lookup followed it. Reopening verifies the exact filename
in the native file list, not a separate byte-for-byte readback of that exported
file. The [case timeline and source-log hashes](evidence/pdf-export-645036e.json)
are retained for review.

The `afa1a72` failed import cases now have matching creation and post-test
identity evidence from the same run. Current cancellation's 8,220-byte PDF
retains SHA-256, device/inode and modification time between 09:03:54.135753 and
09:09:49.911586 UTC. At 09:04:31.565946, FileProvider reports -1005 with resolver
-1012; an empty internal delegate array follows at 09:04:31.566477. The complete
App log has no importer callback marker for that namespace, so this is not proof
that SwiftUI delivered a successful empty array to the App. SE save's 8,235-byte
PDF likewise retains identity between 09:03:59.340001 and 09:06:03.321123, but
has neither an App callback marker nor a matching provider/bookmark error; its
cause must remain separate. Current save received `success count=1` at
09:05:52.871939 and failed only after tapping Save. Before/after PDF identity does
not prove uninterrupted presence at the exact error, nor that an exported TXT
was written. These observations narrow the evidence gap without establishing a
provider root cause or fix.
The synthetic-only [identity/timeline comparison](evidence/file-provider-afa1a72.json)
is retained with this repository; original logs and recordings remain in the two
linked workflow artifacts.

Additional source checkpoints:
- `0df511b` [workspace 42769973948](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42769973948): large/current passed 31/31 selected native/hosted/UI cases, including login, protected HTTP, per-site removal and relaunch. SE passed 30/31: login passed, but removal completed at 30.719 seconds with zero synthetic cookies, after the first 30-second wait failed; subsequent HTTP/relaunch assertions did not execute. All three hosted targets passed 11/11, including actual WKDownload, zero skips. `e941709` shares the existing total 60-second allowance across removal and record refresh, keeping empty-list, HTTP and relaunch assertions. Targeted [SE workspace 42778341962](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42778341962) failed as recorded above. Workspace/all honor the login case's existing 420-second declaration; other scopes remain capped at 300. The four unexplained 60-second XCTest idle waits in the prior SE case remain open, not a proven product fix.
- `1747c20` [workspace 42763765491](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42763765491): completed with the failures and timings above. The bounded persistent website-removal phases and failure cleanup evidence do not themselves fix cookie removal.
- `08ebb8f` [iOS 17.5 42762808616](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42762808616): booted 17.5/21F79 and reached the 80-minute test deadline. Completed log records show 98 native passed; UI 40 passed, three failed and ten explicit live-service skips. Hosted cases were not reached. Bookmark rename failed its label assertion after Save; two PDF export cases failed App termination in teardown. Two basic UI cases started without a final result and are not counted. The result summary was empty/incomplete. Report/log/bundle artifact was saved at 07:19 UTC; cancellation was requested at 07:52 after runner cleanup remained stuck for over 30 minutes. This remains a timed-out, incomplete acceptance run regardless of its eventual cancellation label. Targeted [17.0.1 startup 42777363564](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42777363564) on `8f89d9e` selected the basic UI class; its pre-test boot failure is recorded below.
- `1bc4549` [iOS 17.5 workspace 42779156342](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42779156342): booted and passed all 38 selected native/hosted cases (Domain 27, hosted 11), zero skips. The UI runner then failed to initialize because it timed out waiting for the AX-loaded notification. No UI case executed; the summary records that runner error as a separate failed entry (38 passed/one failed), not as one of the five intended UI cases. Report exit 65 and selected/runtime acceptance flags remain false. Source includes the shared website-removal budget and bookmark-title publication wait. In the failed `08ebb8f` bookmark case, the exact input passed and the later AX/screenshot showed the correct new title on the same bookmark, with no error; the immediate post-Save assertion was premature. The new bounded five-second wait retains history/relaunch checks. This does not retroactively pass persistence, which the failed case never reached.
- `8f89d9e` [iOS 17.0.1 startup 42777363564](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42777363564): failed before App tests. The selected 21A342 runtime reached terminal `Data Migration Failed` after 5m56s; the runner correctly rejected simctl's misleading zero exit code. Diagnostic help timed out and device-state inventory was unavailable; the dedicated simulator was deleted. No UI case executed. This preserves the earlier 114/114 core result but leaves basic UI on the minimum runtime unverified; it is not an App assertion failure.
- `024aba9` [Transporter 42764461574](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42764461574) and [unsigned Release 42764485075](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42764485075): the unsigned run was cancelled while queued and replaced with [42765470430](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42765470430) on `c8ff84a` to include the new authoring App code. Transporter installation/startup passed; the replacement unsigned run passed, including actual build number 14, nine device binaries and minimum OS 17.0. It remains unsigned/not installable. No signing/upload mode was dispatched.

The optional TestFlight delivery path has 32 passing local Python tests using
synthetic artifacts and substitute subprocesses. The official Transporter 4.3.0.4
installer was actually downloaded and its SHA-256 and Apple installer certificate
verified locally without installation. The separate hosted Transporter check then installed and launched the actual tool successfully. Account authentication, real distribution
signing, Apple upload, processing and tester availability remain unverified.

[iOS 17.0.1 core 42769127673](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42769127673)
on `1b0f3d8` **passed 114/114 selected native/hosted cases**, zero failures,
skips or expected failures. Actual runtime inventory is iOS 17.0.1 / 21A342,
iPhone 15 x86_64 simulator on macOS 15.7.9 / Xcode 16.4 (16F6), deployment target
17.0. Counts are Domain 48, Models 6, MCP 15, Memory 5, Skills 25, Persistence 4
and BrowserIntegration 11. All three raw-address validation layers and all five
new authoring bridge methods passed, including actual encrypted-file readback.
The 11 hosted cases include actual WebKit DOM, download, per-site cookie removal,
independent tabs and deferred navigation restrictions. UI was not selected:
`selected_tests_succeeded=true`, `runtime_tested=false` intentionally records
scoped success, not full App acceptance. The bridge test key store is an in-memory
test backend; this is not manual authoring UI/relaunch evidence. Boot succeeded;
optional inventory and shutdown diagnostics were incomplete, while deletion of
the dedicated simulator succeeded. This replaces `c8ff84a` run 42765526169,
cancelled because of the known test-target compilation error.

### Original-script container acceptance

[Run 42770104969](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42770104969)
on `2d67d87` built the pinned official Python 3.12.16 image and passed 16 actual
containers, 12 unchanged-worker-entrypoint requests and ten acceptance groups.
The downloaded report confirms exact extraction, metadata, page order/duplicates,
empty pages, encrypted PDF wrong/right password handling, malformed/path/hash/page
refusals and rejection of a modified scratch copy of the original script.
Effective UID/GID 65534, zero capabilities, no-new-privileges, read-only root,
64 MiB writable tmpfs, loopback-only networking / external ENETUNREACH and cgroup
limits (768 MiB, zero swap, one CPU, 32 PIDs) were checked inside the containers,
in addition to Docker configuration checks. All four packaged source hashes match
the committed source. No image or authenticated remote endpoint was published;
this does not verify App-to-production connectivity or full original-skill parity.

### Manual skill authoring increment

A typed search/read/prepare/review/commit bridge is connected to the bundled
skill-authoring detail screen. It uses LearningStore's existing encrypted snapshot
and publishes success only after durable persistence. This is a manual authoring
flow, not model-autonomous tool execution. The pinned Mika documents are unchanged.
Local direct Swift execution passed five groups / 51 checks (26 ordinary conditions
and 25 expected-error checks), using actual AES-GCM files with an in-memory key
provider. Those map to five native XCTest methods, not 51 test cases. Four new UI
cases cover create/relaunch, refusal/relaunch, read/update/relaunch, and invalid-tool
rejection. The original [authoring 42765232695](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42765232695) passed 103 portable cases on SE, including all five authoring methods, then failed test-target compilation because its private `name` property collided with XCTestCase.name. Remaining jobs were cancelled; no iOS authoring UI pass is inferred. The property was renamed to `fixtureSkillName` in `1b0f3d8`. Files SE/large then compiled the complete UI target and ran the five authoring bridge cases on iOS. Replacement 42769111436 was cancelled while all three jobs were queued. [Authoring 42772009461](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42772009461) on `5d85da4` subsequently passed large 9/9, SE/current 8/9 each; targeted `616178d` SE/current both passed 9/9. Exact per-case outcomes and the earlier failures are recorded above.

### Earlier increment evidence

Integrated source `d160a24` was tested in [files 42748349250](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42748349250)
and [workspace 42748354209](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42748354209).
The current-runtime partial logs confirm 97 portable cases and the files run's
12 original-script worker cases passed, including the real Swift HTTP client.
App builds and built native-document plist checks passed. Files results on all
three variants retain five PDF-selection failures; native upload and cancellation
passed on all three. The PDF exists and is enabled in the actual native Files
evidence; the test tapped its text instead of its file cell/thumbnail. The test
now targets that exact synthetic cell without broadening the PDF type filter.
Workspace SE/current hosted cases all passed, including actual download,
published titles, per-site cookie clearing and deferred-navigation restrictions.
Their UI result is 2/5: password entry is obscured after opening the keyboard,
and native Select All triggers XCTest's default alert interruption handler.
Tests are being repaired with native page scrolling and end-of-field deletion,
retaining real HTTP authentication, exact title, persistence and logout assertions.
Queued parity `42748359276` and live-model
`42748365051` were cancelled before starting to prioritize iOS 17 installers
in the runner queue; these cancellations are not test failures.

The same source passed [unsigned Release 42748369961](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42748369961):
nine device binaries, App minimum OS 17.0, SDK 26.2, actual document-sharing
flags true, Release ATS key absent. It is explicitly unsigned/not installable;
neither physical-device execution nor signed distribution is inferred.

Source checkpoints: `9ddc30d` (workspace), `a74df45` (file transfers and PDF),
`bd2f8d0` (iOS file protection fix, hosted workspace and release workflow),
`7b11555` (build verifier and bookmark test repair). Later source refinements are
not covered by these runs until explicitly retested.

- `42741528413` on `9ddc30d`: 83 portable tests passed; 6 browser-library and 4
  hosted WebKit tests passed. Workspace UI 2/3 passed: independent tab state and
  metadata restoration, manual query page and real JavaScript confirmation.
  Bookmark rename failed because native tapping placed the cursor inside the
  prefilled long title; the exact replacement assertion detected the residual
  suffix. The test now uses native Select All; the original failure is retained.
- `42743895000` on `a74df45`: iOS build found two wrong FileManager argument labels
  inside an iOS-only file-protection branch. Corrected in `bd2f8d0`; CLT/macOS
  validation alone did not cover that branch.
- `42744271971` on `bd2f8d0`: all three App builds passed. Native file selection
  could not reach the App Documents folder; cancellation passed on large/current
  upload and on all PDF variants, but selection-dependent cases failed. Explicit
  built plist booleans and bounded native routing are now under repair. All three
  hosted workspace cases stopped on empty published titles; profile deletion also
  found retained store references. Both product title timing and teardown are
  corrected for the next run. Real WKDownload passed on both iOS 18.5 sizes;
  iOS 26.2 reported an InvalidTransition during the direct-start harness path.
- `42744266742` on `bd2f8d0`: Release iPhoneOS build completed but Mach-O audit
  failed. The audit incorrectly treated LC_BUILD_VERSION linker-tool version as
  an OS version; parsing was corrected in `7b11555`, and `42745303603` on `7b11555` passed: Xcode 26.2, iphoneos 26.2 SDK,
  actual minimum OS 17.0 across nine binaries, Release ATS key absent. Signature
  and runtime checks are explicitly false; this is not installable release evidence.
- `42744261931` on `bd2f8d0`: Apple installer exited 0; iOS 17.0.1 build
  21A342 was installed and selected (runtime identifier iOS-17-0). simctl bootstatus
  exceeded 300s before any App test. It is a boot-timeout result, not a download
  failure. `098abd3` adds a bounded 900s first boot and preserved diagnostics.
  `7b11555` separately fixes the isolated Debug plist input path. No iOS 17 App
  runtime success is assumed.

Local non-XCTest evidence: browser library 6 scenarios/57 assertions, initial
navigation permits 4/27, download core 101 assertions, real WKDownload 27,
upload real HTTP/file/lifecycle 129 plus actual WebKit form/status 7. PDFKit
standalone assertions and original-script Python suite 12/12 (zero skips) passed,
including the real Swift HTTP client. These do not substitute for iOS native
Files interaction. Release/tooling Python suite currently has 64 passing tests.

## MCP / DOM / bundled-catalog increment — implemented scope accepted

The implemented increment has passing simulator and live-service evidence below.
The final App source is `bd1df7f`; later `267e295` and `c16a040` change only fixture
test scrolling and workflow selection. The original three-size run retains its SE
failure; the affected complete case subsequently passed in the targeted run. This
is composite, revision-specific evidence, not a claim that the original matrix
was green or that full Mika parity / iOS 17 physical-device acceptance is complete.

New code connects selected MCP tools/resources to a model conversation, exact
per-call approval, bounded execution, cancellation and reviewable received results.
The MCP runner uses strict JSON commands over the existing model transport; it does
not yet implement provider-native function-call streaming, OAuth, stdio or legacy SSE.
Tool schemas are supplied verbatim; schema enforcement remains the server's job.
Server annotations never grant consent. Limits: 12 model calls, 6 operations, 180s.
The App reports attempts and received results separately; cancellation cannot undo
an operation that reached the server. No automatic tool retry occurs. Malformed
model commands receive at most one format correction per conversation, charged to
the same model-call/time budget; strict command parsing and per-call approval remain
unchanged. The `31bac09` live diagnostic identified `invalidCommand` on model call 1,
with zero proposals, dispatch attempts or received results, before this correction
was added.

Browser additions are observed DOM IDs and individually reviewed click/type/select/
scroll operations, a single-step model proposer, back/forward/reload. Actual event
dispatch does not assert site task success. Forms remain constrained by the existing
public-HTTPS navigation policy, synthetic events, no frames/closed shadow DOM,
no password/file input, and no tabs/login/download parity. Interaction events do not
silently become readonly route evidence or verified skills.

The pinned Mika catalog contains all six bundled skills, three support files,
LICENSE and NOTICE; original bytes/hashes are verified. Original scripts remain
inert. Separately labeled iOS text adaptations use pending-review → approved trial,
and do not claim execution parity with the original skills.

Local evidence before final iOS CI: MCP 458 checks (234 existing + 224 new), catalog 255
and existing Skills 643, DOM policy 80 and real macOS WebKit DOM 29, App MCP
network/namespace isolation 16, private-runner injection/cleanup 9. App logic typechecks
with Swift 5.8 (old macOS WebKit delegate-isolation warnings remain); full SwiftPM is
unavailable on this CLT-only host. Three new catalog UI, three DOM UI, five MCP UI,
one real-model/public-site DOM UI and two combined real-model/HA UI cases have separate
CI evidence below. Three hosted App navigation cases were added after the first live
load failure; they use real local WebKit documents and explicitly synthetic failure/
termination delegates, not a claim of actual OS process termination. Local checks do
not count as iOS UI or live-service success.

USB inventory currently contains no connected iPhone; local Xcode selection is
Command Line Tools. iOS 17 physical-device validation remains unperformed.

### Increment evidence and resolved test failures retained for review

Final candidate `bd1df7f` includes the single bounded MCP format correction and
fixture harness fixes. [Three-size acceptance](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42728389857)
now includes 21 UI cases: MCP 5, DOM 3, catalog 3, browser learning 3, memory 6,
and memory race 1, plus native/core coverage. [Real HA acceptance](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42728394145)
is separate and passed: native audited HA checks, discovery/reconnect UI and both
real-model/HA cases, zero skips. The successful two-tool flow reported three model
decisions, zero format corrections, exactly two attempts/two results/zero tool
errors. Its refusal case preserved the draft. Format-correction behavior was
exercised by deterministic tests; this successful live run did not need it. No
HA mutations were sent. The completed matrix and subsequent targeted retests are
recorded separately:

| Execution / revision | Evidence | Result |
|---|---|---|
| App `bd1df7f`, iPhone 16 Pro Max / iOS 18.5 | [129540250710](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42728389857/job/129540250710) | 77 portable + 66 native + 21 UI passed; zero failures/skips |
| App `bd1df7f`, iPhone 17 / iOS 26.2 | [129540251033](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42728389857/job/129540251033) | 77 portable + 66 native + 21 UI passed; zero failures/skips |
| App `bd1df7f`, iPhone SE / iOS 18.5 | [129540251078](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42728389857/job/129540251078) | 77 portable + 66 native passed; UI 20 passed, 1 failed; zero skips |
| Test-only `267e295`, same App source, SE Memory UI group | [42735292745](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42735292745) | 77 portable passed; UI 5/6 passed, zero skips; import now succeeds, rollback button lookup fails later |
| Test-only `c16a040`, same App source, SE skill update/rollback | [42737745483](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42737745483) | 77 portable and the complete UI case passed (89.321s); zero failures/skips; rollback and relaunch/full-text assertions executed |
| App `bd1df7f`, actual HA and model | [42728394145](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42728394145) | Native HA checks and all three live UI cases passed; zero skips; zero mutation calls |
| Browser/learning App source `43e7094`, test revision `bcc7850` | [42727021885](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42727021885) | Seven native model calls and complete real five-page learning UI passed; zero skips; App browser/learning files unchanged in `bd1df7f` |

The matrix's native 66 cases are MCP 15, Skills 15, Domain 32 and hosted Browser 4.
Its 21 UI cases are MCP 5, DOM interaction 3, browser learning 3, catalog 3,
Memory 6 and Memory race 1. Each device passed all ten hosted/interaction/learning
browser cases and all three catalog cases. This targeted suite is not the older
full 33-case fixture suite. The real-service runs are separate from these fixtures.

The initial SE failure was `testSkillUpdateRejectionAndRollback`, before tapping
`skills.import`. Its fixture AX evidence placed the import row at y=595.5…639.5,
with a usable list viewport ending at y=611. Full-list swipes alternated past the
row. `267e295` changes only the test harness/workflow: a measured, bounded drag
accounts for the actual gap plus a margin, holds before release to avoid inertia,
and still requires the entire control to be visible/hittable before a semantic tap.
It does not coordinate-tap or skip the rollback assertions. Twenty-two local
geometry cases (93 assertions) passed. The SE retest successfully imported the
original skill, a rejected update, and an approved second version. It then failed
at the rollback button in the unchanged generic scrolling helper: the control was
present before a full swipe, then absent after that swipe and seven more upward
swipes. The remaining failure is not evidence of a failed rollback operation;
the button was never tapped. The other five Memory UI cases passed.
`c16a040` applies the already exercised measured gesture only to `skills.rollback.*`
in this suite. Its full-text, rollback-content and relaunch assertions are unchanged;
the other five cases and shared learning UI helper are unchanged. The focused
workflow reruns the affected complete case rather than only a button tap.
That focused case passed: the semantic rollback tap, full-text view containing
`VersionOne`, App termination/relaunch and the repeated document-content assertion
all executed. This UI assertion checks the version marker, not byte-for-byte equality
of the entire skill document.
Together with the unchanged five cases that passed at `267e295`, this closes the
six-case SE Memory group. It does not change the failed conclusion of the older run.
The SE two-step clear test now passes with its exact saved-text assertion, without
any change to production deletion behavior.

Reproduce the selected acceptance suites from a checked-out revision with `gh`:

```sh
gh workflow run ios.yml --ref main -f test_scope=parity -f current_only=false -f compact_only=false
gh workflow run ios.yml --ref main -f test_scope=memory-ui -f compact_only=true -f current_only=false
gh workflow run live-mcp.yml --ref main
gh workflow run live-model.yml --ref main -f ui_scope=browser-learning
```

Live runs require the repository secrets/variables documented in README. The
commands target the branch's current commit; inspect each run's recorded SHA before
comparing evidence. They do not request or prove signed-device distribution.

- Full `40c6b1b` regression [42721186819](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42721186819): iPhone 17 and Large jobs succeeded; SE failed three fixture UI cases. SE/iPhone 17 each passed 74 portable and 75 native cases. Their UI results were respectively 30/33 and 33/33, with ten opt-in live skips each. Catalog 3/3 and MCP 5/5 passed on both.
- SE final fixture evidence clarified the failures: the disabled DOM row was absent from the virtualized AX tree, not proven enabled; the skill-import gesture overshot a previously visible row and searched only farther down; the clear test had initially saved `Keep uil both confirmations` rather than its intended text. Cancel had preserved that actual record. `MemoryDataView` already reset list identity on segment changes, so no product scroll reset was added. Tests retain exact assertions and add bounded visible-row search, first-key/chunk verification and a pre-clear saved-text assertion.
- `43e7094` hosted focus [42724088534](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42724088534): DOM UI 3/3 and the three new App navigation-state cases passed. The older DOM integration fixture failed with `InvalidTransition: idle → failed(deinit)`. `bcc7850` waits for the exact navigation's `didFinish` rather than `isLoading`, uses the callback evaluation API, and prints a fixed fixture stage on failure. All 29 original DOM assertions remain; local macOS execution passed. These fixture changes do not establish the old WebKit failure's exact internal cause.
- `43e7094` live model [42724084043](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42724084043): seven native probes and 6/7 App UI cases passed. Five-page initial loading completed in 2.237 seconds, with actual six-action research, judged completion and pending draft checks passing. The case then failed on the destination header after tapping Memory; approval/relaunch was not reached. `bcc7850` observes native section selection after the single tap and retains the destination assertion; [targeted real-flow verification](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42727021885) passed all seven native calls and the complete five-page UI case (241.640s, zero skips). Both Memory transitions reported selected=true/status=true; explicit draft review/approval and byte-identical relaunch passed. Its App browser/learning source is unchanged from `43e7094`; the test adds selection observation, not a second tap or a relaxed learning assertion.
- `31bac09` live HA [42724339138](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42724339138): native HA, discovery/reconnect and refusal passed; the two-tool case failed with `phase=requestingModel; modelCalls=1; attempts=0; results=0; failure=invalidCommand`. This is evidence of a rejected model command, not a network timeout or failed tool call. `bd1df7f` adds the single bounded format correction, without echoing invalid model content into feedback or weakening the parser.

- `fe62cf9`, [42718456191](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42718456191): MCP 5/5 and catalog 3/3 fixture UI cases passed on all three sizes. The first browser cases failed in the test harness: fixed browser navigation was incorrectly checked against the Form viewport, and the WebKit native test had no App host. `40c6b1b` adds a hosted test bundle and separates fixed chrome visibility from Form scrolling.
- `cfa1761` (App source `40c6b1b`), [42721768042](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42721768042): iPhone 17 passed all three actual-DOM interaction UI cases and the hosted WebKit case; 74 portable cases also passed. No assertions were removed to obtain this result.
- `fe62cf9`, [42718460902](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42718460902): live HA discovery/reconnect UI and both real-model/HA UI cases passed. Native discovery found 77 tools and 17 resources; audited read-only calls/resource retrieval passed; mutation calls sent = 0.
- `40c6b1b`, [42721190807](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42721190807): native HA and discovery/reconnect passed, as did the real-model refusal case. The two-tool case timed out waiting for its **first** proposal; no tool was approved. The old logs cannot distinguish the reason. `31bac09` adds fixed phase/counter diagnostics and model failure categories without retrying, changing deadlines, or weakening approval/command validation.
- `f01f16e`, [42719715579](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42719715579): seven native model probes and 6/7 real UI cases passed, including an observed IANA About link proposed by the model and approved navigation to its actual URL. Five-page learning failed during the initial page load, before research. `43e7094` adds fixed load phases, terminal observation errors, and generation/navigation identity checks so failed or superseded pages cannot become current through late completion. The 75-second initial-page assertion is unchanged.
- The initial standalone learning probe lacked explicit `observedURL` metadata on its synthetic actions. Adding the complete fixture metadata produced `done` with five citations, five unique actions, five observed URLs and two judge/drafter calls; eligibility rules were unchanged. The original failure log did not include sufficient detail to prove this was its sole cause.

Live model/MCP logs contain only fixed categories, counters and test results; no
live screenshots, full accessibility trees, tool bodies or xcresult artifacts are
published. A passing retry on a later revision does not identify an earlier cause
that was not logged. The final matrix's one SE failure is retained above; earlier
passes are not silently reassigned to changed production code.

## Previous browser/learning acceptance checkpoint

That earlier browser/learning increment passed the full simulator matrix and
real-model App flow described below. The broader App remains in development; this
is not full Mika feature parity. Fixture, native-network and live UI evidence are
reported separately.

Application source `2654965` includes the browser/learning integration, the native
modal container, exact reviewed provenance, trusted UUID validation, bounded
model-command correction and measured cold-start allowances. That checkpoint's full matrix
uses this revision; live test revision `fbe4669` changes only its navigation wait,
with identical App production source. Earlier evidence remains
listed by source revision and must not be confused with current acceptance:

| Execution / revision | Evidence | Current result |
|---|---|---|
| Full App regression, `2654965`: SE / iPhone 16 Pro Max / iPhone 17 | [42708706919](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42708706919) | All three jobs succeeded; each passed 65 portable, 65 iOS native and 22 fixture UI tests; 7 opt-in live cases skipped in normal CI |
| Native model probes and six real App UI cases, test revision `fbe4669`, App source `2654965` | [42711916423](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42711916423) | Seven native probes and all six UI cases passed, zero skips; complete multi-page approval/relaunch passed in 157.434 seconds |
| Local skill assertions | 643 checks; strict-concurrency build, three consecutive passes | Passed; not iOS UI evidence |
| Local research assertions | 238 checks; strict-concurrency build | Passed; no live model/network |
| UI visibility geometry | 24 standalone checks | Passed; not iOS UI evidence |

All three final simulator jobs have zero test failures. The normal matrix skips six
opt-in model UI cases and one HA case; the six model cases were separately executed
against the real service with **zero skips**. The previously documented HA read-only
acceptance is separate evidence and was not silently counted as part of this run.

The full fixture matrix includes actual WebKit research, pending-skill review,
explicit approval, exact relaunch persistence, website knowledge/revisions and
confirmed six-step route replay. It also verifies real DOM exclusion while research
is presented and restoration after dismissal. The live five-page case covers real
IANA/model research through explicit approval and byte-identical relaunch; it does
not substitute for a live route-replay test or a complete Mika catalog/browser audit.
Physical iPhones, iOS 17 runtime, signing/distribution and full browser interaction
remain outside this completed simulator increment. Phone/native-app control stays
excluded by the agreed scope.

<details>
<summary>Earlier checkpoints (revision-specific, superseded where stated)</summary>

| Execution / revision | Evidence | Current result |
|---|---|---|
| Native model probes and six real App UI cases, `2654965` | [42708715736](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42708715736) | Seven native probes and 5/6 UI cases passed. Multi-page passed real sources/actions/done/pending checks, then native navigation readiness failed; approval/relaunch not reached |
| Full App regression, `daf0152`: SE / iPhone 16 Pro Max / iPhone 17 | [42707028819](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42707028819) | Superseded after the inherited modal-boundary failure was confirmed |
| Native model probes and six real App UI cases, `daf0152` | [42707038595](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42707038595) | Superseded while queued; no result claimed |
| Full App regression, `896e447`: SE / iPhone 16 Pro Max / iPhone 17 | [42697447884](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42697447884) | SE and iPhone 17: 65 portable + 65 native + 22 fixture UI passed each, 7 opt-in skips. Large: 21/22 UI; invalid-input test received 199 rather than 201 characters |
| Browser regression, `67e1d4e`: same three devices | [42701757230](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42701757230) | All three failed the new whole-WebView absence assertion; large also failed initial page readiness |
| Native model probes and six real App UI cases, `67e1d4e` | [42701765437](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42701765437) | Seven native probes and 5/6 UI cases passed. Multi-page stopped after one inspection with invalid_command_json; no learning pass claimed |
| Earlier live attempt, `896e447` | [42697453900](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42697453900) | Seven native probes and five UI cases passed; multi-page UI exceeded 300 seconds after research finished. Approval/relaunch unverified |

</details>

Earlier successes and failures below are revision-specific history. Fixture passes
do not substitute for real model, website, or App interaction evidence.

## First modal accessibility attempt (later superseded)

The `896e447` live multi-page case reached the fixed App status “研究已結束”,
but subsequent accessibility queries took roughly 5–10 seconds each; its first
result-scroll gesture occurred near the 300-second case limit. This does not prove
that the answer, learning verdict or pending skill satisfied acceptance. The earlier
short research failure at `5f58196` did not recur; its precise cause remains unknown.

The first attempt set hiding flags on the retained WKWebView while research was
presented and restored them on dismissal/dismantling, leaving its renderer and DOM
running. Subsequent fixture runs showed those flags alone did not exclude the actual
DOM. The native-container correction below replaced this insufficient boundary.
The UI helper reuses its scroll container and allows partially visible **static text**
to be read, while controls must remain fully visible before tapping. Twenty-four
standalone geometry assertions passed. The 300-second limit and all six-action,
full-answer/source, exact-verdict, explicit-approval and byte-identical relaunch
assertions remain unchanged. The fixture additionally checks that browser accessibility
is excluded during the sheet and restored afterward.

## Fixture input and modal-content checks

Full `896e447` run completed without a step timeout. All three devices passed all
three browser cases, including actual fixture navigation, skill review/relaunch and
route replay. SE and iPhone 17 each passed all 22 fixture UI cases. Large passed 21;
its single memory-validation failure was investigated with the exported PNG and AX
tree: the editor had saved **199** characters, although the test sent a burst intended
to contain **201**. There was no hidden validation message: this input was valid.
The test now waits for the keyboard and verifies each input segment, then checks
exactly 201 characters before Save. It neither retries nor repairs lost input and
retains the existing validation-error and unchanged-draft assertions. No production
memory validation behavior changed.

At `67e1d4e`, the new whole-WebView absence assertion failed on both iOS 18 devices.
A native container's existence is not the intended assertion about page content.
The corrected fixture checks its real DOM heading before presentation, absence
while the research sheet is open, and restoration after dismissal. It still requires
all five actual navigations and the complete learning/relaunch flow. Failure artifacts
now include the fixture-only AX tree. Large also failed 45-second initial loading:
the PNG shows the correct full URL, dismissed keyboard and blank loading WebKit.
The runtime cause remains under investigation; no timeout was increased for this
failure. Subsequent learning/full results are recorded below and at the current checkpoint.

## Reproduced runtime failures and bounded corrections

Real run `67e1d4e` completed seven native requests and 5/6 UI cases. The multi-page
case stopped after its initial real inspection with `invalid_command_json`; no
navigation, answer or skill was invented. The single-page IANA case passed again.
The browser now permits **one format correction per entire task** after a command
fails strict JSON decoding. It asks for a new valid command, without retaining or
executing the rejected reply. This consumes the existing 12-call/180-second budget;
second format failure, unsupported actions, bad arguments, unknown links, HTTP
failure and cancellation still stop. No fenced-JSON extraction or action alias was
added. **238 standalone assertions** pass, including bounded corrective calls,
non-execution, exact action counts and cancellation while correcting.

The large-device cold-start failure has direct runtime evidence: WebContent took
**57.480968 seconds** and GPU startup 57.590726 seconds for the same App PID. The
45-second readiness wait began at 21:30:16.590 UTC and expired at 21:31:01.605;
WebContent started only at 21:31:08.682. Cold navigation with no prior observation
now permits 75 seconds; warmed navigation remains 25 seconds and the overall task
budget remains 180 seconds. Fixture/live initial readiness waits 75 seconds and
fixture route completion 105 seconds. Case limits and functional checks are unchanged.
This explains the missed startup deadline, not the underlying hosted-runtime latency.

Learning run [42705232922](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42705232922)
at `0e1d415` exposed a separate portable-test crash on the current device's runner,
before iOS native/UI testing. A runtime UUID's numeric segments could pass the Luhn
check and be mistaken for a card number in trusted `learned_from` metadata. The
result was a rejected draft and a test force-unwrap crash. A fixed collision UUID
now reproduces this path deterministically. Parsing exempts only the single canonical
UUID metadata line matching the trusted runtime/stored identity; raw model/import
text, duplicate metadata, mismatched identities, body text and descriptions retain
the original privacy checks. Approval, encrypted snapshot decode, context retrieval,
export and revision restoration are covered. **643 skill assertions passed three
consecutive runs**, including 40 additions. The failing fixture now checks the
proposal and reports its outcome/skip category instead of force-unwrapping it.

The final full simulator matrix and real-model run at the current checkpoint
provide the subsequent acceptance; local checks alone were insufficient.

The completed `0e1d415` learning matrix recorded 65 portable and 28 native passes
on each iOS 18 device, with **9/10 UI cases passed** each and no skips. All seven
memory/skills cases passed, including the corrected exact-201-character validation
flow. Large failed the modal DOM-heading absence check. SE failed the five-second
keyboard-absence wait before that check; its later screenshot and AX tree showed
the keyboard closed. The record cannot distinguish delayed dismissal from delayed
AX queries, and no additional wait was added for that failure. The current-device
runner passed 46 portable methods before the UUID-related fixture crash; no iOS
native/UI tests ran there. These are historical failures, not current passes.

## Native modal container correction

The `0e1d415` learning matrix's large-device case found the actual fixture DOM
heading still present in the automation tree after opening research, before Start.
The direct WKWebView flags were therefore insufficient for the intended boundary;
the unchanged absence/restoration assertions remain mandatory. `daf0152` inherited
that implementation, so its full/live runs are superseded rather than accepted.

A native UIView now contains the same retained WKWebView with four-edge constraints.
During research, both `accessibilityElements` and `automationElements` are empty,
with accessibility descendants hidden. Dismissal restores both lists to the WebView.
The renderer, DOM and mounted layout continue operating. Dismantling resets and
removes the WebView only if the old container still owns it, so an old wrapper cannot
undo a replacement wrapper's policy. This is the production modal behavior, not a
UI-test-only branch. Apple's [WWDC23 accessibility session](https://developer.apple.com/videos/play/wwdc2023/10035/)
explains the distinct accessibility and automation lists; the
[`automationElements` API](https://developer.apple.com/documentation/objectivec/nsobject-swift.class/automationelements)
is available from iOS 17. The final three-device fixture runs subsequently passed
the actual DOM boundary assertions, and the live run completed the full review flow.
This is automated UI evidence, not a physical-device VoiceOver usability audit.

## Real multi-page learning reaches review handoff

Live `2654965` run [42708715736](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42708715736)
passed seven native calls and 5/6 UI cases. The multi-page case completed actual
IANA navigation, all five full-URL answer citations, exactly six completed reads
(initial inspect plus five unique navigations), and the exact independent done plus
saved-pending-draft status. Modal state queries now took fractions of a second.
This establishes progress through draft creation, not approval/relaunch acceptance.

After closing research, the full Protocol Registries accessibility tree was restored.
The test's address query took roughly ten seconds; the subsequent native
`navigation.memory` readiness predicate expired at five seconds before a successful
navigation. No model/answer/provenance assertion failed. The test helper now uses
`firstMatch` for the known native navigation identifier and a bounded 15-second
exists-and-hittable wait, then still requires the destination's real status. On
failure it records only that fixed native identifier, booleans, geometry and elapsed
time. The 300-second case limit and every source, action, verdict, explicit approval,
trial-state and byte-identical relaunch assertion remain. This is a test-only change;
App production code remains `2654965`, and its full simulator matrix is preserved.

## Executed locally

- XcodeGen 2.44.1 generated the project; plist and Swift syntax checks passed.
- Contracts/domain standalone executable: 519 assertions, 42 state-transition edges,
  20 concurrent-start / terminal-race rounds. This was not XCTest.
- Browser policy standalone executable: 1,510 assertions, 768 policy decisions.
  This tests URL policy, not WebKit or complete SSRF protection.
- Model native fixture executable: 310 assertions; request validation, JSON and SSE,
  truncation, total deadline, cancellation, bounds, no retries, redirect rejection.
- MCP native fixture executable: 234 checks in five groups, including negotiation,
  session headers, large SSE, tool allowlist, pagination, errors, deadline and cancellation.
- Python scripts: 41 unit tests for simulator selection/runtime setup, private runner
  configuration, and MCP probe read-only boundaries/redaction.
- Full local `swift test` remains unavailable: this host has Command Line Tools,
  not full Xcode/XCTest. GitHub-hosted Xcode is used for actual XCTest and iOS.

## Actual model service tests

An owner-provided OpenAI-compatible service was tested without storing credentials
in source. Python's default User-Agent received HTTP 403; an explicit application
User-Agent received HTTP 200. This correlation does not establish the gateway's
internal blocking rule.

- JSON: exact `WOOW_OK`, HTTP 200; 1,647 total tokens reported by the provider.
- SSE: exact `WOOW_OK`, three content chunks, normal `[DONE]` termination, HTTP 200.
- These probe results alone do not validate the iOS UI or native networking.

## Actual Home Assistant MCP service tests

The owner-provided webhook is held as a secret, never in this document. The first
probe rejected a tools/list SSE line exceeding 64 KiB; the corrected bounded parser
accepted the actual large event with a 4 MiB response limit.

- Negotiated protocol `2025-03-26`; stateless; capabilities tools/resources/prompts/logging.
- Discovered 77 tools, 17 resources, zero resource templates and zero prompts.
- Initialization, initialized notification, ping and unknown-method error `-32601` passed.
- Real read-only calls passed: `ha_get_overview`, `ha_list_floors_areas`,
  `ha_list_services`, `ha_search`, `ha_get_state` for an actually discovered entity,
  `ha_get_skill_guide`, `ha_config_get_dashboard` (list only, no configuration or image),
  and `ha_eval_template` with only the literal arithmetic template `{{ 1 + 1 }}`.
- A documentation/guide resource was read successfully. Resource contents, household
  values and entity identifiers were not logged.
- Missing entity and unknown tool returned tool-level errors normally.
- No device control, service calls, configuration changes, restarts, deletions,
  camera images or other mutating requests were sent.
- Repeated the same real-service acceptance with the production Swift `MCPClient`
  on macOS: initialize/notification/ping, all catalogs, eight read-only tools,
  missing-entity business error and guide resource read passed. An unallowlisted
  service-control call was rejected locally without sending a request. This is
  native client evidence, not an iOS Simulator or App UI pass.

Catalog discovery is not execution of all 77 tools. Prompts/templates have no positive
real-server case because this server advertises empty catalogs. Mutating tests require
an owner-selected target and permitted actions. OAuth, legacy SSE, stdio, subscriptions,
sampling/elicitation and model-driven tool selection are not implemented/accepted.

## GitHub iOS evidence

Public source: https://github.com/WOOWTECH/woow-assistant-ios

Baseline run [42626174672](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42626174672):
core tests and actual simulator build ran successfully, but **4/5 UI tests failed**
on navigation accessibility/hit testing. This run is not a pass. The parent navigation
accessibility modifiers were removed and the UI suite expanded; rerun required.

Prepared regression matrix: iOS 18.5 iPhone SE (3rd generation), iOS 18.5 iPhone 16 Pro
Max, iOS 26.2 iPhone 17. Normal CI retains fixture-only logs, screenshots and xcresult.
Manual live model and live HA workflows test native networking plus App UI; they never
upload live xcresult/xctestrun/process environments, which may contain credentials.

Expanded matrix run [42630794706](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42630794706)
was an intermediate checkpoint; later revision-specific results below supersede it.
Live model run [42630881158](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42630881158)
passed both native JSON and SSE requests inside the iOS 18.5 simulator, but all three
App UI cases failed before chat because bootstrap did not establish saved settings.
Simulator builds had explicitly disabled code signing; the next revision enables
ad-hoc signing and adds sanitized Keychain OSStatus diagnostics to test the suspected
credential-store failure. This is not yet a confirmed root cause or passing UI result.
After simulator ad-hoc signing was enabled, run
[42633296355](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42633296355)
passed both iOS 18.5 variants (iPhone SE and iPhone 16 Pro Max): 37 native unit tests
and 12 fixture UI tests each. Four opt-in live tests are deliberately skipped in
normal CI, not counted as passes. The iOS 26.2 variant passed 37 unit and 11 UI tests;
one removal UI test failed because its confirmation dialog exposes nested buttons
with the same identifier. The locator now also checks the intended action label and
uses the first matching wrapper; persistent deletion and model-setting isolation
assertions remain. A focused iOS 26.2 rerun is required.

Live HA/model retries
[42633367501](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42633367501) and
[42633373248](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42633373248)
first failed before executing any step because GitHub could not allocate hosted
arm64 runners. On the second attempt, the actual iOS 18.5 native HA acceptance
passed: initialization, ping, catalogs, eight read-only tools, documentation read,
business-error handling and local rejection of an unapproved control tool.
The live model second attempt passed both native requests and all three actual
App UI tests (zero skips): multi-turn reply/context and draft-preserving navigation,
live cancellation, and actual HTTP failure with a dummy credential at an invalid
domain. Isolated test credentials were cleared during teardown. The live HA second
attempt also passed the complete actual App UI case (zero skips): bootstrap into
isolated Keychain, explicit connection/discovery, background disconnect, reconnect,
manual disconnect and credential cleanup. There were two actual discovery cycles.
Both manual workflows finished successfully. Infrastructure allocation failures
are separate from App test failures.

Focused iOS 26.2 regression after the confirmation-locator fix:
[42636866904](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42636866904),
failed the same deletion case: 37 unit and 11 UI tests passed; the status remained
saved immediately after tapping the duplicate wrapper. The log cannot distinguish
an ineffective wrapper tap from a stale UI snapshot. The next test revision chooses
the last exact action match and waits for the actual state transition, while keeping
the relaunch-persistence and model-setting-isolation assertions. It is not yet a pass.

Follow-up [42640697815](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42640697815)
at `b8da579` completed successfully on iOS 26.2. This closes the pre-learning
confirmation regression, not acceptance of the subsequent memory/Skills increment.

## Remaining acceptance gaps

- Actual iOS 17 runtime and physical iPhone testing; build deployment target 17 does
  not prove runtime compatibility.
- MCP App UI tool invocation and model-to-MCP orchestration; UI currently discovers
  catalogs only. Native tool authorization is caller-reviewed, not model-controlled.
- Complete built-in skill catalog, profile consolidation, persistent conversation/files,
  notifications, language/appearance, signed distribution and App Store review.
- Full Mika browser capabilities, including login, forms, tabs, history, downloads,
  uploads and the remote gateway. Read-only WebKit research, automatic skill drafts,
  website knowledge and route replay are a separate increment with evidence below.
- UserDefaults required-reason entry added for app-owned preferences; the manifest
  is not a substitute for a final privacy/distribution audit.

Reference: [Apple TN3183](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest).

## Memory / Skills implementation increment

Pinned source and scope are in [MEMORY_SKILLS_PARITY.md](MEMORY_SKILLS_PARITY.md).
The implementation now includes encrypted memory/skill snapshots, memory CRUD,
pending procedures, bounded contextual retrieval, separate quote-validated model
extraction, cancellation/revision guards, import/review/trial/disable/revision/export
of personal text skills, and independent memory/skill preferences. Clear-all is
twice-confirmed, rotates the learning key and does not delete model/MCP settings.

Executed locally:

- Memory core: 91 assertions in five groups, including quote/secret guards,
  capacity, context bounds, undo, atomic operations, cancellation and late-result rejection.
- Skills core: 179 assertions in six groups, including parser/import/review,
  optimistic revisions, outcome rules, retrieval and trusted learning gates.
- AES-GCM persistence: round-trip, ciphertext/plaintext separation, key rotation,
  failed-key-write preservation, unreadable-key write guard and explicit reset.
- App learning store, Keychain adapter and chat integration typechecked with the
  actual native modules; SwiftUI syntax parsed. This is not an iOS build.
- Three actual owner-authorized model requests using the production Swift clients
  on macOS: automatic Traditional Chinese preference extraction, fresh-conversation
  recall via memory context, and an approved text skill changing the actual reply.
  Pending/disabled skills were excluded; no skill was promoted merely for a reply.
  The memory-off path produced neither memory context nor an extraction request.
  No real household data or response bodies were logged.

Actual iOS 18.5 model workflow
[42646342662](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42646342662)
at `17e750f` **passed**: native JSON/SSE, three real learning requests, and all four
App UI tests (zero skips). The memory UI case verifies real extraction, encrypted
persistence across termination/relaunch, recall in a fresh conversation, and no
recall after disabling memory without deleting the record. Native learning also
verifies approved text-skill influence, pending/disabled exclusion, no promotion
from an ordinary reply, and rejection of credential-bearing URLs/synthetic identity
data. No action-derived automatic drafting is exercised by these passes.

Earlier live runs
[42643616002](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42643616002)
(`20f2eab`) and
[42645456186](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42645456186)
(`91d480a`) passed native requests and three UI cases, but failed the memory UI case
at the off-switch assertion (value remained `1` after tapping the outer accessibility
wrapper). Selecting the nested native switch when present and waiting for its value
transition fixed the latest live test; persistence/recall assertions were not relaxed.

Full fixture matrix
[42644351064](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42644351064)
at `d58dd6d` **failed on all three variants**; it is not full acceptance:

| Simulator | Core XCTest | Fixture UI | Failing learning UI cases |
|---|---:|---:|---|
| iOS 18.5 SE 3 | 52 passed | 16 passed, 3 failed | Keywords field keyboard focus; preference switches; skill switch |
| iOS 18.5 16 Pro Max | 52 passed | 15 passed, 4 failed | Clear race; preference switches; skill switch; clear cancellation/isolation |
| iOS 26.2 iPhone 17 | 52 passed | 17 passed, 2 failed | Preference switches; skill switch |

Each full variant additionally skipped five opt-in live cases; these are not passes.
All 12 existing non-learning UI cases passed on all three variants. The seven new
fixture cases use the real production store/encryption but fixture-only model HTTP.
The generation-race and clear-isolation tests passed on SE/iOS 26.2, not yet on the
large variant. The race fix prevents an old main reply from starting extraction
after clear/edit; new-conversation notes are also cleared.

The large-device failure log shows `memory.clear` reported hittable, yet the next
accessibility snapshot had the bottom Tools navigation selected, not a confirmation
sheet. The SE keyword test reported no keyboard focus after a purported field tap.
Revision `93acfa7` adds bounded scrolling that requires the complete target frame
inside visible content above navigation/keyboard, and dismisses/waits for the editor
keyboard before changing fields. It does not bypass either clear confirmation or
retry a destructive tap. Underlying layout correctness remains subject to rerun.

Focused matrix
[42649999149](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42649999149)
tested `d2615fe`: compact and current variants passed all 15 focused native cases
and seven fixture UI cases. Large failed: its first UI case repeatedly stalled on
60-second animation-idle waits, and the remaining six UI cases did not run. It is
not a pass; the animation trigger is unproven. The next checkpoint enables XCTest
execution timeouts (the prior runner reported testTimeoutsEnabled:NO despite each
test's declared allowance) and uses fresh simulators.
It includes a final review correction: scroll downward when a target's top edge,
not only its midpoint, is above the viewport. It replaces the queued `93acfa7` run
[42649315791](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42649315791) and
supersedes the partially executed `17e750f` focused matrix
[42646588669](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42646588669),
not the completed full-regression evidence above. A superseded/cancelled run is not
a pass. The follow-up changes only UI tests, not the live-tested production modules.
The superseded SE job did finish all seven learning UI cases before cancellation:
six passed, including both repaired switch cases and the clear race; the keyword
focus case still failed. This supports the switch fix, not a whole-job pass.

Automatic action-derived skill drafting, website knowledge, browser login/route
management, native-app knowledge and executable scripts are not implied by these passes.

## Website research / task learning integration — 2026-11-10

New code connects actual WKWebView reads to a bounded read-only research loop,
independent model outcome assessment with exact executed-observation citations,
and pending skill generation. Five distinct successful qualifying actions are
required for a draft; observations/finds do not count. A one-page response can be
judged completed without a skill draft. Reviewed skill versions receive outcome
updates; limits count as failure, network/environment failures as unreviewed, and
user cancellation does not penalize the skill. Late results are generation guarded.

Website knowledge has source quotes, approval, edit/delete/revisions and exact-origin
context. Routes contain observed navigation/read steps only. Explicit replay checks
fresh page URL/quotes, then generates an answer and judges it before recording success.
Two consecutive divergences at the same step disable the route. Research stops at
12 model decisions/180 seconds, replay at 13 steps/180 seconds. Browser uses a
nonpersistent website-data store, public HTTPS URLs without queries/fragments,
and no arbitrary JavaScript, forms, native-app controls or model-selected MCP calls.
The URL policy is not complete DNS/subresource isolation or full Mika browser parity.

Local evidence before CI:

- Website knowledge/routes: 152 offline assertions, strict-concurrency compilation.
- Model-backed skill service: 89 new + 179 existing = 268 fixture assertions;
  strict-concurrency/warnings-as-errors compilation.
- Native App store/chat/browser integration typechecked on macOS SDK; older WebKit
  delegate actor-annotation warnings remain on this host. SwiftUI parsed, project
  generated, Python 36 tests passed. These do not substitute for an iOS build.
- New XCTest cases cover bounded research execution, repeated actions, invalid
  commands, executor failure, website state, learned draft gates, conflicts and
  cancellation. Fixture UI uses actual WebKit with local HTML and fake model HTTP.
- Live workflow now separately tests real WebKit + real model on public IANA pages,
  and real judge/drafter on explicitly labelled synthetic executor evidence. The
  synthetic trace probe is not an end-to-end live browsing/automatic-learning pass.

At this initial checkpoint the iOS build, UI and live results were still pending.
The revision-specific results and corrections follow below.

Checkpoint `798af0b`: matrix [42675608518](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42675608518)
passed 62 portable XCTest cases on each runner, but all App builds failed on a
new error-reporting branch assigning to the implicit immutable `catch error`.
The live workflow [42675616357](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42675616357)
also failed App build; this is not new live-service acceptance. The branch now
uses `self.error`, and native App integration typechecks again.

Cross-review also added immediate browser cancellation when credentials/settings or
learning data change, generation checks before later outbound model calls, bounded
cancellable WebKit observation, visible browser navigation on route replay, and a
fixture UI regression for removing model credentials during research. Skill service
fixtures now total 350 assertions after verifier-failure attribution, conflicting
duplicate references and pre-hash input-bound checks were corrected. These new
changes await their own iOS checkpoint rather than inheriting the old run's result.

### Integration failures and corrections

Checkpoint `17ce4d3` built on all three simulators and passed all 65 portable core
tests. Full current-iOS run [42677218137](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42677218137)
also passed 65 native iOS tests and 19 fixture UI cases (seven memory/skills and
12 existing chat/navigation/MCP cases). The three new browser UI cases failed:
the research sheet's Done button received a valid tap, but the keyboard remained
visible. Six opt-in live cases were skipped, not counted as passes. The sheet now
owns its focus binding in a separate view; the original keyboard assertion remains.

The compact iOS 18.5 focused job in
[42676613926](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42676613926)
passed zero of ten UI cases: the App terminated at launch before their feature
steps. Live run [42676619376](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42676619376)
passed native JSON/SSE, three real memory/skill requests, and two real judge/drafter
requests over synthetic executor traces, but its UI step timed out during repeated
launch failures. These are **not** end-to-end browser or automatic-learning passes.

Exported fixture crash reports in
[42680808120](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42680808120)
identified a pre-main DYLD termination: `libswiftWebKit.dylib` was missing from the
iOS 18.5 simulator's search path. This matches
[Apple's documented simulator defect](https://developer.apple.com/forums/thread/785964)
and [WebKit bug 293831](https://bugs.webkit.org/show_bug.cgi?id=293831).
The CI helper exposes the **selected runtime's own** Cryptex overlay through a
build-products symlink, a directory already present in the failing dyld lookup.
It does not copy a library into the App or raise the iOS 17 deployment target.
Five new helper tests pass, bringing local Python checks to 41. Separately, WebKit
creation is deferred until its screen is requested; that isolation alone cannot
fix a missing library before main, and is not reported as the launch root cause.

`d2d7aa3` also tightens live browser acceptance to the exact judged-done message:
the former substring `完成` could match a partial or failed result. Its queued
focused live run [42678843137](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42678843137)
was cancelled once the startup defect was established. No pass is claimed for it.
The initial lazy-WebKit startup run at `9aa129d` was superseded by the runtime-path
correction at `22e5906`. Checkpoint `cf0300c` includes both runtime setup and the
sheet focus fix; its new matrix/live evidence must be evaluated separately.

At `22e5906`, startup run [42682325627](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42682325627)
completed its SE job: 65 portable tests and the actual App all-section navigation
case passed (28.201 seconds for UI). The runtime overlay fix therefore has an
actual launch pass. Remaining queued startup variants were cancelled in favor of
the more complete learning/browser suites; the whole startup matrix is not a pass.

At `cf0300c`, the SE and large jobs of
[42682474716](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42682474716)
each passed all seven memory/skills UI cases plus two browser cases (cancellation
after removing model settings, and manual website knowledge across relaunch).
Each failed the remaining browser skill/replay case: approval stripped the
runtime-owned `learned_from` UUID from the reviewed Markdown. The seven memory
passes also supersede the prior large-device animation stall for these cases.
The queued iOS 26 job was cancelled only after both iOS 18 jobs had finished.

Live run [42682483793](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42682483793)
passed all seven native real-model requests and four existing real App UI cases.
Its fifth case stopped before website loading: the first WebKit address-field
accessibility query exceeded the five-second readiness check. No live website
research pass is inferred. The browser-only rerun now allows a bounded 15-second
initial readiness check and records only elapsed time, existence/hit-test booleans
and geometry. Goal, answer and exact judged-done assertions remain unchanged.

`39d853a` separately fixes route reuse: a new `originalGoal` preserves exact case,
whitespace and Unicode spelling for display, model input and judgment; normalized
`intent` is only a lookup key. Older records remain readable but cannot recover
case/whitespace already lost by the prior format. Website/route offline checks
now total 185. Its SE/large browser jobs in
[42684081657](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42684081657)
also passed two of three browser UI cases, then stopped at the same provenance
assertion before route replay. The current-iOS variant was superseded by the next
browser checkpoint, not counted as passed.

`23a20ab` retains only the **original stored learned draft's valid UUID** across
approval/editing, after stripping untrusted edited metadata. Imported/forged IDs
remain excluded and export still removes local provenance. All 380 skills fixture
assertions pass, including 30 new checks for exact Markdown, provenance forgery,
serialization and export. The unchanged UI equality assertion now requires this
fix to succeed before continuing to actual route replay.

At `23a20ab`, browser matrix
[42688005093](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42688005093)
passed on all three devices: **65 portable tests, 19 focused native tests and all
three browser UI cases on each device**. This includes the entire learned-draft
review/approval/relaunch flow and actual persisted-route replay, with exact answer
and judged-success assertions. These UI cases use local HTML and fixture models.
The independent full iOS 26 run at the same revision encountered a page-load wait
failure in the manual-website case; the passing focused run does not erase it.

Live browser run
[42688015027](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42688015027)
passed seven native real-model requests. The actual address was hittable after
1.428 seconds and the public page loaded, but its UI test timed out waiting for the
answer accessibility row. It did **not** pass browser acceptance. The next test
waits for task completion at the visible start control, then scrolls the Form to
the answer and verdict, retaining both assertions. Fixed App-owned phase messages
provide diagnostics without model content or secrets. This is a test correction
for lazy rows, not evidence that the earlier run delivered a successful answer.

Further source review found that host-only URL masking could collapse distinct
requested/answered paths before outcome judging. Judge input now uses a shared,
request-local URL identity map; case, query and UTF-8 differences remain distinct.
Raw URLs are still masked. URL identities cannot become grounded source quotes;
only unchanged original text outside masked URLs may support the verdict. Unknown
or planted identities fail closed. Draft generalization remains unchanged. The
mapping covers extracted URLs; unquoted trailing prose punctuation is ambiguous,
while quoted literals retain it. Strict-concurrency/warnings-as-errors compilation
and **501 standalone skill assertions** pass, including 121 new identity/citation
checks. New iOS/live evidence is required for this correction.

A new opt-in live UI case performs five actual public IANA navigations, requires
exact judged completion and a validated pending skill, then approves and reloads
the exact reviewed Markdown. No injected trajectory or model fixture is used.
A local macOS WebKit preflight confirmed all five visible-link transitions and
that all six observations pass existing evidence hygiene. That preflight is not
an iOS or real-model end-to-end acceptance result. The one-off startup-diagnostics
workflow was removed after identifying the runtime defect; normal fixture CI now
exports those diagnostics itself.

Source-identity follow-up: browser observations now carry an explicit optional
`observedURL` from the completed executor result. The judge receives only its
`sourceURLIdentity`, shared with goal/answer identities, so it can tie a cited URL
to the corresponding observed page. Requested arguments and URLs embedded in
page prose cannot establish that provenance. Exact typed URLs bypass prose
punctuation trimming; the new field participates in input and sensitive-data
bounds before masking. **603 standalone skill assertions** pass (102 new checks),
and the actual App adapter typechecks with the updated module. Native App checking
on this old macOS SDK retains its existing WebKit actor-annotation warnings; it
is not represented as an iOS acceptance result.

### Cold WebKit startup and real multi-page diagnostics

Full `23a20ab` run
[42688899398](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42688899398)
recorded 65/65 portable, 65/65 native and **21/22 fixture UI** passes; six opt-in
live cases were skipped. The manual-website failure remained at initial loading.
Its App diagnostic log measured **25.754479 seconds to launch WebContent** and
25.890365 seconds for the GPU process, exceeding the test's 15-second readiness
wait. The run also hit the 30-minute Test step limit before xcresult finalization;
raw failure attachments and diagnostics were preserved. It is not a full pass.

At `5f58196`, browser matrix
[42692240898](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42692240898)
passed all three UI cases on the large device. Current iOS passed cancellation and
manual knowledge, but the skill case stopped at the same initial-load wait with
the correct address, no keyboard/error and a blank loading WebKit view. SE passed
the first two cases and the skill review/relaunch portion, then stopped on route
replay before its first page observation. Cold navigation previously had a
25-second timeout. These failures do not indicate a new provenance/judge failure.

The correction permits 45 seconds only when navigation has no prior observation;
warmed navigation stays at 25 seconds and the research/replay deadline remains
180 seconds. Fixture initial-load readiness now waits up to 45 seconds and route
completion up to 75 seconds, preserving all actual-page, quote, answer, judgment
and persistence assertions. The CI step limit is 40 minutes (job limit 60) so a
full suite can finalize its results. These bounds address observed cold-start
latency, not arbitrary retries or replacement of execution with fixture success.

Live `5f58196` run
[42692247932](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42692247932)
passed seven native requests and **5/6 App UI cases, zero skips**. The actual IANA
single-page research passed, including an independently judged done outcome and
no invented skill. The new five-page case failed in the research phase about four
seconds after Start, before an answer or skill draft; its generic error did not
identify the cause. It remains an acceptance failure, not a learning success.

Research now distinguishes command decoding, unsupported commands, unavailable
links, model transport/HTTP failures, navigation failure, navigation timeout and
page-read timeout. User messages are fixed; DEBUG tests add only a fixed category
and actual completed-action count. Replay uses the same diagnostics. Raw responses,
URLs, credentials and underlying error descriptions are excluded. **202 standalone
research assertions** pass, including non-execution of rejected commands, accurate
completed-action counts and error-content redaction. No additional command format,
automatic retry or navigation permission was enabled in that diagnostic increment.
Later evidence identified invalid command JSON; the bounded format correction and
final successful strict live flow are recorded above.
