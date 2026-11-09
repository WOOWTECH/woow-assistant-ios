import Foundation

@main
enum MCPSettingsChecks {
    static func main() throws {
        let id = UUID().uuidString
        let regular = ["-UITestMode", "-UITestNamespace", id]
        let model = ["-LiveModelUITest", "-LiveModelUITestNamespace", id]
        let combined = model + ["-LiveMCPConversationUITest"]
        var count = 0
        func check(_ condition: Bool) {
            precondition(condition, "App MCP network isolation policy failed")
            count += 1
        }
        for args in [regular, model, regular + ["-UITestMCPFixture"],
                     combined + ["-LiveModelUITestCleanup"], combined + ["-UITestMode"],
                     combined + ["-UITestNamespace", id], combined + ["-LiveModelUITestNamespace", id],
                     ["-LiveMCPConversationUITest"], ["-LiveModelUITest", "-LiveMCPConversationUITest"]] {
            check(!MCPSettingsStore.networkAllowed(arguments: args))
        }
        check(MCPSettingsStore.networkAllowed(arguments: combined))
        check(MCPSettingsStore.networkAllowed(arguments: regular + ["-LiveMCPUITest"]))
        check(!MCPSettingsStore.networkAllowed(arguments: regular + ["-LiveMCPUITest", "-LiveMCPUITestCleanup"]))
        // Invalid flags must fail before any production Keychain access.
        for args in [["-LiveMCPConversationUITest"], ["-LiveModelUITest", "-LiveMCPConversationUITest"],
                     combined + ["-UITestMode"], combined + ["-LiveModelUITestNamespace", id]] {
            do {
                _ = try MCPSettingsStore.makeDefault(arguments: args, environment: [:])
                preconditionFailure("Invalid private test namespace was accepted")
            } catch MCPSettingsError.invalidTestNamespace { count += 1 }
        }
        print("PASS: \(count) App MCP network/namespace isolation checks")
    }
}
