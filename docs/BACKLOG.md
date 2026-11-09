# Initial backlog

## M0 — Foundation

- [x] Create the iOS 17 XcodeGen project definition.
- [x] Establish contracts, domain run state, browser URL policy and CI skeleton.
- [x] Generate the Xcode project and validate its plist structure.
- [x] Push the user-approved public repository and run the first macOS CI build (baseline UI failed; see verification log).
- [x] Add explicit run state events and regression tests for cancellation, waiting, terminal states and concurrency.
- [x] Make scaffold navigation reachable on iPhone and preserve drafts without pretending to send.
- [x] Pin CI tooling and preserve logs / xcresult on failure.
- [ ] Add SwiftLint / formatting after the first successful Xcode build.

## M1 — Conversation core and browser shell

- [ ] SwiftData storage for conversations, messages, run events and outbox records.
- [x] Native JSON/SSE model transport with bounded requests and fixture coverage.
- [x] Configurable actual model conversation, cancellation and retained drafts.
- [ ] Stream partial model output into the chat UI.
- [ ] `WKWebView` tab manager: navigation, history, bookmarks, site mode and process recovery.
- [ ] Decide explicit opt-in local-network browsing policy; the starter URL filter defaults to public destinations and does not yet satisfy full Mika parity.
- [ ] Files import, attachment metadata and safe download vault.
- [ ] XCTest / XCUITest fixtures for run cancellation, app relaunch and browser navigation.

## M2 — Controlled connections

- [x] HTTPS Streamable HTTP MCP client, explicit tool allowlist, bounded requests and discovery.
- [x] Keychain-backed model keys and whole MCP endpoints; no plaintext credentials in preferences or logs.
- [x] User-configurable MCP endpoint with discovery/cancel/disconnect UI.
- [x] App-level tool/resource selection and bounded model-to-MCP orchestration with explicit per-call approval cards (simulator/live acceptance tracked in VERIFICATION).
- [ ] OAuth PKCE, explicit session reinitialization UI and other required transport modes.
- [ ] Authorized real-device HA control tests (target and allowed actions pending).
- [ ] Declarative Skills registry and remote compute job contracts.

## M3 — Browser parity and notifications

- [x] Page reader, grounded research and fixed DOM action bridge with single-action approval (full browser parity remains open).
- [ ] Optional remote browser gateway contract for CDP-only capabilities.
- [ ] Notifications for completed jobs and approval requests.
- [ ] Real-device iOS 17 validation matrix, TestFlight metadata and App Review demo mode.
