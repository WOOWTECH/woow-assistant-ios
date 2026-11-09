# Initial backlog

## M0 — Foundation

- [x] Create the iOS 17 XcodeGen project definition.
- [x] Establish contracts, domain run state, browser URL policy and CI skeleton.
- [x] Generate the Xcode project and validate its plist structure.
- [ ] Push the private repository and run the first macOS CI build.
- [x] Add explicit run state events and regression tests for cancellation, waiting, terminal states and concurrency.
- [x] Make scaffold navigation reachable on iPhone and preserve drafts without pretending to send.
- [x] Pin CI tooling and preserve logs / xcresult on failure.
- [ ] Add SwiftLint / formatting after the first successful Xcode build.

## M1 — Conversation core and browser shell

- [ ] SwiftData storage for conversations, messages, run events and outbox records.
- [ ] Streaming `ModelClient` protocol plus deterministic SSE fixture client.
- [ ] `WKWebView` tab manager: navigation, history, bookmarks, site mode and process recovery.
- [ ] Decide explicit opt-in local-network browsing policy; the starter URL filter defaults to public destinations and does not yet satisfy full Mika parity.
- [ ] Files import, attachment metadata and safe download vault.
- [ ] XCTest / XCUITest fixtures for run cancellation, app relaunch and browser navigation.

## M2 — Controlled connections

- [ ] HTTPS Streamable HTTP MCP client, session recovery and OAuth PKCE.
- [ ] Keychain-backed credential references; no tokens in logs or persistence.
- [ ] User-configurable MCP endpoint trust and explicit approval cards; catalogue support must not remove endpoint configuration.
- [ ] Declarative Skills registry and remote compute job contracts.

## M3 — Browser parity and notifications

- [ ] Page reader, citations, page ask and safe DOM action bridge.
- [ ] Optional remote browser gateway contract for CDP-only capabilities.
- [ ] Notifications for completed jobs and approval requests.
- [ ] Real-device iOS 17 validation matrix, TestFlight metadata and App Review demo mode.
