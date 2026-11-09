# Verification — 2026-11-09

This is an in-progress implementation, not full-feature acceptance. Tests distinguish
fixtures, real network calls, iOS UI, and unimplemented functionality.

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
- Python scripts: 36 unit tests for simulator selection, private runner configuration,
  and MCP probe read-only boundaries/redaction.
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
is executing; iOS 26.2 portable core and App build passed, UI results pending.
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
- WebKit browser, automatic task-to-skill learning and outcome judging, complete
  built-in skill catalog, profile consolidation, persistent conversation/files, notifications,
  language/appearance, signed distribution and App Store review.
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
tests `d2615fe` on all three simulators; **results pending** at this checkpoint.
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
