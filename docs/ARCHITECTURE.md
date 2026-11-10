# Architecture decision record — iOS assistant

## Product boundary

The target scope is model conversations, memory, file work, controlled MCP connections, declarative skills, WebKit browsing, notifications, language and appearance. Not all are implemented; see the verification log. It never controls other iPhone apps, uses Accessibility to automate the device, records the screen, runs ADB, or executes arbitrary local programs.

## Modules

`AssistantContracts` owns Codable messages shared with the future gateway. `AssistantDomain` owns run state without UI dependencies. `AssistantBrowser` owns URL policy, research/website/route state, DOM approval validation and a fixed isolated-world WebKit adapter. `AssistantModels` owns JSON/SSE networking; `AssistantMCP` owns Streamable HTTP and a bounded model conversation runner. Memory, Skills and encrypted persistence have separate modules. The app target owns SwiftUI, foreground sessions, settings and device-only Keychain adapters.

## Browser modes

`local_webkit` is the only default mode. Its cookies and login data remain in the app's WebKit data store. `remote_browser` is a later, opt-in server capability for CDP-grade automation; it never receives local cookies, passwords, OTPs or Passkeys automatically.

## Implemented execution boundaries

MCP discovery starts only from an explicit connection action. The user selects tools/resources to disclose to the configured model. The runner receives that immutable catalog and the same connection; it accepts only strict JSON commands, proposes exact arguments or resource URIs, and waits for an App approval callback. The callback cannot replace the operation. Connection/selection changes, backgrounding, cancellation and the 180-second deadline invalidate outstanding work. The runner permits at most 12 model requests and 6 executions, rejects duplicate operations, and does not retry side effects. Attempt counts are distinct from received results. Tool errors stop execution while preserving received results for review.

Browser research remains read-only. The separate interaction entry point observes stable document/node IDs, asks the model for one action, and waits for a native review. A one-use grant expires after 60 seconds. Before dispatch, fixed JavaScript checks document/snapshot identity, the actual node reference and its captured attributes/form values. All values cross the WebKit argument bridge; no model-supplied JavaScript runs. DOM events are synthetic; dispatch is not proof of a completed website task. Interaction traces are not automatically treated as read-only routes or successful skill-learning evidence.

The bundled skill catalog is a pinned, hash-checked archive of original documents and scripts, displayed as inert text. Separately labeled iOS text adaptations enter the same pending review and trial workflow as imported skills; neither reading nor approving text grants MCP or DOM execution authority. Selected PDF execution has a separate two-step runtime with native PDFKit and an optional pinned-original-script worker adapter. The worker has real local stdio/HTTP tests but no deployed authenticated service. Remote gateway, full original-skill tool registration, provider-native function-call streaming and full browser parity remain unfinished.

- Credentials belong in Keychain, never SwiftData, logs or chat content.
- MCP is an outbound client. Server annotations and descriptions never authorize calls; the remote server validates its input schema. OAuth, stdio and legacy SSE remain unsupported.
- Skills are reviewed text context, not local executable programs. Optional remote computation must be distinguished from iOS capabilities.
- Approval is bound to the current immutable operation and run. Neither a model answer nor a saved JSON boolean is an approval credential.


## Browser workspace and files

BrowserWorkspace owns one persistent WebKit profile and a separate BrowserSession/WKWebView per live tab. Metadata is encrypted with a dedicated device Keychain key; known callback/secret URLs are excluded. Manual HTTPS navigation accepts login/query URLs while model research retains its existing public-page restrictions. Switching/closing tabs revokes pending proposals. Website-record removal first quiesces every old document, then removes the selected records; history/bookmarks and learning data have separate deletion controls.

A workspace-wide BrowserDownloadManager receives real WKDownload objects, retains WebKit authentication context, bounds file/count/time usage, cleans partial files and shares only validated completed files. BrowserNavigationIntent binds download permission to manual navigation and one-use callbacks. Native WebKit file inputs use the system chooser on iOS 17. DEBUG upload fixtures permit only an exact loopback origin/path; the loopback ATS exception is in the Debug plist only. Release builds have no fixture server or ATS exception.
