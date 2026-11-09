# Architecture decision record — initial iOS foundation

## Product boundary

The target scope is model conversations, memory, file work, controlled MCP connections, declarative skills, WebKit browsing, notifications, language and appearance. Not all are implemented; see the verification log. It never controls other iPhone apps, uses Accessibility to automate the device, records the screen, runs ADB, or executes arbitrary local programs.

## Modules

`AssistantContracts` owns Codable messages shared with the future gateway. `AssistantDomain` owns run-state and approval data without UI dependencies. `AssistantBrowser` owns URL policy and later WebKit adapters. `AssistantModels` owns JSON/SSE networking; `AssistantMCP` owns bounded Streamable HTTP and explicitly allowlisted tool calls. The app target owns SwiftUI, foreground sessions, settings and device-only Keychain adapters.

## Browser modes

`local_webkit` is the only default mode. Its cookies and login data remain in the app's WebKit data store. `remote_browser` is a later, opt-in server capability for CDP-grade automation; it never receives local cookies, passwords, OTPs or Passkeys automatically.

## Security requirements for future implementation

Credential storage and MCP transport are implemented with native networking and regression tests. Authenticated approval execution, model-directed tools, a skill installer and browser gateway remain requirements, not implemented protections. The MVP MCP screen only discovers catalogs; server annotations never authorize tool calls.

- Credentials belong in Keychain, never SwiftData, logs or chat content.
- MCP is an outbound client; support user-configured endpoints with explicit trust and credential boundaries. A server catalogue must not replace Mika-compatible configuration.
- Skills import and execution need an explicit format and trust model; local iOS execution and optional remote computation must be distinguished. No skill executor is implemented yet.
- External writes require an approval whose run, target, payload hash and expiry all match.
