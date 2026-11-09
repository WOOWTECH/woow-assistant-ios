# Verification — 2026-11-10

The implemented browser/learning increment has passed the full simulator matrix and
real-model App flow described below. The broader App remains in development; this
is not full Mika feature parity. Fixture, native-network and live UI evidence are
reported separately.

## Current acceptance checkpoint

Application source `2654965` includes the browser/learning integration, the native
modal container, exact reviewed provenance, trusted UUID validation, bounded
model-command correction and measured cold-start allowances. The latest full matrix
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
