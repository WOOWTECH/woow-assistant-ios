import Foundation
import AssistantDomain

@main enum CheckTaskNotificationCore {
    @MainActor static func main() async {
        var groups: [String: Int] = [:]
        do {
            let cases: [(String, () async throws -> Void)] = [
                ("defaultOffAndPermission", TaskNotificationChecks.defaultOffAndPermission),
                ("permissionAndSettingsRaces", TaskNotificationChecks.permissionAndSettingsRaces),
                ("enableRefreshOverlap", TaskNotificationChecks.enableRefreshOverlap),
                ("transitionsAndExpiry", TaskNotificationChecks.transitionsAndExpiry),
                ("inFlightAddCancellation", TaskNotificationChecks.inFlightAddCancellation),
                ("boundsRelaunchAndRevocation", TaskNotificationChecks.boundsRelaunchAndRevocation),
                ("observerLifecycle", TaskNotificationChecks.observerLifecycle),
                ("testButtonAndRoutes", TaskNotificationChecks.testButtonAndRoutes)
            ]
            for (name, body) in cases {
                let before = TaskNotificationChecks.assertions
                try await body(); groups[name] = TaskNotificationChecks.assertions - before
            }
            let result: [String: Any] = ["status": "PASS", "assertions": TaskNotificationChecks.assertions,
                "groups": groups, "actual_xctest_bodies": true, "native_xctest_execution": false,
                "system_notification_center_access": false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            print("FAIL: " + ((error as? TaskNotificationChecks.Failure)?.check ?? "synthetic_check_failed")); exit(1)
        }
    }
}
