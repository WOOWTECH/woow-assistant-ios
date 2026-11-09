# Architecture decision record — initial iOS foundation

## Product boundary

The app supports model conversations, memory, file work, controlled MCP connections, declarative skills, WebKit browsing, notifications, language and appearance. It never controls other iPhone apps, uses Accessibility to automate the device, records the screen, runs ADB, or executes arbitrary local programs.

## Modules

`AssistantContracts` owns stable Codable messages shared with the future gateway. `AssistantDomain` owns run state and approvals without UI dependencies. `AssistantBrowser` owns URL policy and later WebKit adapters. The app target owns SwiftUI presentation only.

## Browser modes

`local_webkit` is the only default mode. Its cookies and login data remain in the app's WebKit data store. `remote_browser` is a later, opt-in server capability for CDP-grade automation; it never receives local cookies, passwords, OTPs or Passkeys automatically.

## Security requirements for future implementation

These are requirements, not implemented protections. The current contracts have no credential store, authenticated approval executor, MCP transport, skill installer, or browser gateway.

- Credentials belong in Keychain, never SwiftData, logs or chat content.
- MCP is an outbound client; support user-configured endpoints with explicit trust and credential boundaries. A server catalogue must not replace Mika-compatible configuration.
- Skills import and execution need an explicit format and trust model; local iOS execution and optional remote computation must be distinguished. No skill executor is implemented yet.
- External writes require an approval whose run, target, payload hash and expiry all match.
