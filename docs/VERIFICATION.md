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

Latest expanded matrix/native/live-UI runs: pending execution at this commit.

## Remaining acceptance gaps

- Actual iOS 17 runtime and physical iPhone testing; build deployment target 17 does
  not prove runtime compatibility.
- MCP App UI tool invocation and model-to-MCP orchestration; UI currently discovers
  catalogs only. Native tool authorization is caller-reviewed, not model-controlled.
- WebKit browser, Skills, persistent conversation/memory/files, notifications,
  language/appearance, signed distribution and App Store review.
- UserDefaults required-reason entry added for app-owned preferences; the manifest
  is not a substitute for a final privacy/distribution audit.

Reference: [Apple TN3183](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest).
