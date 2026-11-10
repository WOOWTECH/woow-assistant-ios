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

- [ ] Encrypted conversation archive, list and explicit reopening implemented and locally checked; native/UI acceptance pending. Unfinished operations never replay on restore. Durable run events/outbox remain separate.
- [x] Native JSON/SSE model transport with bounded requests and fixture coverage.
- [x] Configurable actual model conversation, cancellation and retained drafts.
- [ ] Stream partial model output into the chat UI.
- [x] Persistent WebKit profiles, independent live tabs, encrypted bookmarks/history and metadata restoration (acceptance tracked per revision).
- [ ] Site-mode controls and full process/login recovery parity.
- [ ] Decide explicit opt-in local-network browsing policy; the starter URL filter defaults to public destinations and does not yet satisfy full Mika parity.
- [x] Manual native browser file chooser, bounded WKDownload storage, progress/cancel/share/delete and selected-PDF import/execution.
- [ ] General chat attachments, file metadata and output workspace integration.
- [x] XCTest / XCUITest fixtures for run cancellation, app relaunch and browser navigation, including hosted WebKit integration (revision-specific acceptance in VERIFICATION).

## M2 — Controlled connections

- [x] HTTPS Streamable HTTP MCP client, explicit tool allowlist, bounded requests and discovery.
- [x] Keychain-backed model keys and whole MCP endpoints; no plaintext credentials in preferences or logs.
- [x] User-configurable MCP endpoint with discovery/cancel/disconnect UI.
- [x] App-level tool/resource selection and bounded model-to-MCP orchestration with explicit per-call approval cards (simulator/live acceptance tracked in VERIFICATION).
- [ ] OAuth PKCE, explicit session reinitialization UI and other required transport modes.
- [ ] Authorized real-device HA control tests (target and allowed actions pending).
- [x] Complete pinned Mika bundled-source catalog with hashes/licenses and separately reviewed iOS text adaptations.
- [x] Capability dependency inventory, per-step PDF grants, native PDFKit and pinned original PDF-worker protocol/tests.
- [x] Manual skill-authoring bridge with original-request/read-version/review binding and atomic encrypted persistence; native UI acceptance tracked per revision.
- [x] Build and execute the pinned original PDF worker in actual isolated GitHub Ubuntu containers; verify effective restrictions and exact results. No endpoint deployed.
- [x] Model-autonomous skill search/read and reviewed-save integration; real-model App flow passed at `6d480d8` (VERIFICATION).
- [x] Configurable App appearance with model list/set and independent default-off permission; native/live acceptance pending by revision.
- [x] Original content-transcribe guidance over approved text/subtitle files and browser text snapshots; core HTTP checks pass, native/live acceptance pending by revision.
- [ ] Full original-skill tool registry and deployed authenticated remote compute environment.

## M3 — Browser parity and notifications

- [x] Page reader, grounded research and fixed DOM action bridge with single-action approval (full browser parity remains open).
- [ ] Optional remote browser gateway contract for CDP-only capabilities.
- [x] Default-off notification preferences and completed-job/approval-request scheduling with real OS permission and notification-tap integration. Pending-approval preservation passed all three simulator variants at f49c8f7; later Chat/UI changes need their own regression. Audible sound and physical-device behavior remain separate.
- [ ] Real-device iOS 17 validation matrix, TestFlight metadata and App Review demo mode.
