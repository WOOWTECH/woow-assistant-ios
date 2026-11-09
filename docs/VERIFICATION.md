# Foundation verification — 2026-11-09

This records the scaffold only, not acceptance of a usable assistant.

## Executed locally

- Generated `WoowAssistant.xcodeproj` using XcodeGen 2.44.1; `plutil` accepted the project structure.
- Confirmed the unit-test target links `AssistantBrowser` and every target inherits iOS 17 minimum deployment.
- Compiled contracts/domain modules with Swift 5.8.1. A separate standalone executable passed 519 assertions covering 42 state-transition edges and 20 concurrent-start / terminal-race rounds. This was **not XCTest**.
- Browser production sources passed Swift typechecking. A compiled standalone harness passed 1,510 assertions across 768 policy decisions, including all 256 second-octet values in `172.*` for IPv4 and mapped IPv6. This was **not XCTest**.
- App and UI test sources passed Swift syntax parsing only, not iOS typechecking.
- Six Python simulator-selection unit tests passed, including missing runtime and iPad-only failures.
- Project/workflow YAML parsed; privacy manifest passed plist validation; `git diff --check` passed.

## Not executed / not complete

- Full `swift test`: blocked by this host's Command Line Tools installation lacking the macOS platform path and XCTest framework.
- iOS build, XCUITest, simulator launch and physical iPhone tests: full Xcode is not installed on this host.
- GitHub Actions: workflow prepared but not yet run. No passing CI result is claimed.
- Model chat, WebKit, files/persistence, MCP, Skills, notifications and remote browser: not integrated. UI explicitly labels these as unimplemented.
- URL filtering is not a complete DNS, redirect, subresource or server-side SSRF protection.
- Approval data structures do not implement authorization or payload binding.

## Prepared CI

`.github/workflows/ios.yml` uses macOS 15, Xcode 16.4 and an available iOS 18.5 iPhone simulator. Actions are pinned to commits; XcodeGen 2.44.1 is checksum-verified. Core tests, script tests, simulator build and unit/UI tests run with pipe failure propagation. Logs and xcresult bundles are retained even on failure. UI tests attach screenshots on launch, section visits and failure, retaining successful captures too. Only deterministic fixture text is used; no model credentials or real customer data are required.

This runner does not demonstrate iOS 17 runtime compatibility. That requires a separately available iOS 17 simulator or physical device.

## GitHub handoff

The connector returned the authenticated profile `WOOWTECH`, but no accessible repositories/installations. The target repository lookup returned 404, which does not distinguish missing from inaccessible. No remote repository creation or push is claimed.

GitHub CLI was downloaded from its official release and checksum-verified. Existing CLI login was absent; official device authorization was started. No token from the conversation was used or stored in the project. The user subsequently approved a **public** repository and GitHub-hosted iOS simulator testing. Once CLI authorization completes, verify its identity, check for an existing target, create the **public** `WOOWTECH/woow-assistant-ios` repository only if absent, push and inspect the actual CI results. Never change the visibility of a pre-existing repository without checking its contents and ownership first.
