import SwiftUI
import AssistantMCP

#if DEBUG
private struct NotificationRouteObservationKey: EnvironmentKey {
    static let defaultValue = ""
}
extension EnvironmentValues {
    var notificationRouteObservation: String {
        get { self[NotificationRouteObservationKey.self] }
        set { self[NotificationRouteObservationKey.self] = newValue }
    }
}
#endif

struct MCPApprovalView: View {
    @Environment(\.appLocalizer) private var localizer
    let proposal: MCPApprovalRequest
    let approve: () -> Void
    let decline: () -> Void
    #if DEBUG
    @Environment(\.notificationRouteObservation) private var routeObservation
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(localizer.text(.mcpApprovalHelp))
                    proposalName
                    #if DEBUG
                    if Self.exposesFixtureIdentity(arguments: ProcessInfo.processInfo.arguments), !routeObservation.isEmpty {
                        // The modal can hide root AX. Mirror its read-only route
                        // value so tests can observe the callback before approval.
                        Text(localizer.text(.mcpRouteObservation))
                            .font(.caption2)
                            .accessibilityIdentifier("mcp.approval.routeObservation")
                            .accessibilityValue(routeObservation)
                    }
                    #endif
                    Text(verbatim: proposal.argumentsText)
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("mcp.approval.arguments")
                    Text(localizer.text(.mcpApprovalRisk))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle(localizer.text(.mcpApprovalTitle))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button(localizer.text(.mcpDecline), role: .cancel, action: decline)
                        .accessibilityIdentifier("mcp.approval.decline")
                    Spacer()
                    Button(localizer.text(.mcpApprove), action: approve)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mcp.approval.approve")
                }
                .padding().background(.bar)
            }
        }
    }

    @ViewBuilder private var proposalName: some View {
        let name = Text(verbatim: proposal.name)
            .font(.headline).textSelection(.enabled)
            .accessibilityIdentifier("mcp.approval.name")
        #if DEBUG
        if Self.exposesFixtureIdentity(arguments: ProcessInfo.processInfo.arguments) {
            name.accessibilityValue(proposal.id.uuidString)
        } else {
            name
        }
        #else
        name
        #endif
    }

    #if DEBUG
    // Reuse the side-effect-free strict mode/UUID parser; never create a store
    // or request permission while rendering this read-only fixture observation.
    static func exposesFixtureIdentity(arguments: [String]) -> Bool {
        guard arguments.filter({ $0 == "-UITestMode" }).count == 1,
              arguments.filter({ $0 == "-UITestMCPFixture" }).count == 1,
              !arguments.contains(where: { $0.hasPrefix("-Live") }),
              let configuration = try? TaskNotificationStoreConfiguration.resolve(arguments: arguments)
        else { return false }
        return configuration.scope != "production"
    }
    #endif
}

struct MCPResultsView: View {
    @Environment(\.appLocalizer) private var localizer
    let steps: [MCPConversationStep]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(Array(steps.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 8) {
                    if case .callTool(let name, _) = step.proposal.action { Text(verbatim: name).font(.headline) }
                    if case .readResource = step.proposal.action { Text(localizer.text(.mcpReadResource)).font(.headline) }
                    Text(step.isError ? localizer.text(.mcpToolError) : localizer.text(.mcpToolResult))
                    Text(verbatim: resultText(step.result))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .privacySensitive().accessibilityIdentifier("mcp.result.\(index)")
                }
            }
            .navigationTitle(localizer.text(.mcpResultsTitle))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localizer.text(.commonClose)) { dismiss() }
                        .accessibilityIdentifier("mcp.results.close")
                }
            }
        }
    }
    private func resultText(_ value: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? localizer.text(.mcpResultUnavailable)
    }
}
