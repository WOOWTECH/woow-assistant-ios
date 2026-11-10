import XCTest

final class TaskNotificationTests: XCTestCase {
    @MainActor func testDefaultOffAndPermission() async throws { try await TaskNotificationChecks.defaultOffAndPermission() }
    @MainActor func testPermissionAndSettingsRaces() async throws { try await TaskNotificationChecks.permissionAndSettingsRaces() }
    @MainActor func testEnableRefreshOverlap() async throws { try await TaskNotificationChecks.enableRefreshOverlap() }
    @MainActor func testTransitionsAndExpiry() async throws { try await TaskNotificationChecks.transitionsAndExpiry() }
    @MainActor func testInFlightAddCancellation() async throws { try await TaskNotificationChecks.inFlightAddCancellation() }
    @MainActor func testBoundsRelaunchAndRevocation() async throws { try await TaskNotificationChecks.boundsRelaunchAndRevocation() }
    @MainActor func testObserverLifecycle() async throws { try await TaskNotificationChecks.observerLifecycle() }
    @MainActor func testTestButtonAndRoutes() async throws { try await TaskNotificationChecks.testButtonAndRoutes() }
}
