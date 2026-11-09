import Foundation

/// Website-only adaptation of Mika RouteStore/RouteReplay at
/// 0c172724f3f0c96f7345262588072f6e95db1138: confirmed outcomes, bounded actual
/// steps, same-path failure preservation and disable after two same-step misses.
/// Unlike native Mika routes there are no app selectors, tool arguments or input slots.
public struct WebRouteState: Codable, Equatable, Sendable {
    public static let maximumRoutes = 100
    public static let maximumSteps = 60
    public private(set) var routes: [WebRoute]
    public private(set) var revision: UUID
    public init() { routes = []; revision = UUID() }

    @discardableResult
    public mutating func record(intent: String, steps: [WebRouteStep], task: WebTaskEvidence) throws -> UUID {
        var item = try WebRoute(intent: intent, steps: steps, task: task)
        var next = self
        if let index = routes.firstIndex(where: { $0.origin == item.origin && $0.intent == item.intent }) {
            let old = routes[index]
            guard task.completedAt >= old.lastUsedAt else { throw WebsiteLearningError.staleRevision }
            let samePath = old.steps.count == steps.count && zip(old.steps, steps).allSatisfy { $0.kind == $1.kind && $0.url == $1.url }
            item = try WebRoute(id: old.id, intent: item.originalGoal, steps: steps, task: task,
                                successes: old.successes, consecutiveMisses: samePath ? old.consecutiveMisses : 0,
                                missStep: samePath ? old.missStep : nil, disabled: samePath ? old.disabled : false,
                                createdAt: old.createdAt)
            next.routes[index] = item
        } else { next.routes.append(item) }
        try commit(next); return item.id
    }

    public func match(originURL: URL, intent: String) throws -> [WebRoute] {
        let origin = try WebsiteOrigin(url: originURL), intent = try WebsiteLearningSafety.intent(intent)
        return routes.filter { !$0.disabled && $0.origin == origin && $0.intent == intent }
    }

    public func replayPlan(id: UUID, originURL: URL, intent: String,
                           expectedContentHash: String) throws -> WebRouteReplayPlan {
        guard let route = routes.first(where: { $0.id == id }) else { throw WebsiteLearningError.notFound }
        guard route.contentHash == expectedContentHash else { throw WebsiteLearningError.staleRevision }
        guard !route.disabled else { throw WebsiteLearningError.disabledRoute }
        guard route.origin == (try WebsiteOrigin(url: originURL)) else { throw WebsiteLearningError.originMismatch }
        guard route.intent == (try WebsiteLearningSafety.intent(intent)) else { throw WebsiteLearningError.intentMismatch }
        for step in route.steps { _ = try WebsiteLearningSafety.publicURL(step.url) }
        return WebRouteReplayPlan(routeID: route.id, contentHash: route.contentHash, origin: route.origin, steps: route.steps)
    }

    /// The caller supplies actual execution observations and a separate task judgment;
    /// merely producing/accepting a plan must never call this with .succeeded.
    public mutating func recordReplayResult(id: UUID, expectedContentHash: String,
                                           result: WebRouteReplayResult) throws {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { throw WebsiteLearningError.notFound }
        guard routes[index].contentHash == expectedContentHash else { throw WebsiteLearningError.staleRevision }
        var next = self; try next.routes[index].note(result)
        guard next != self else { return }
        try commit(next)
    }

    public mutating func delete(id: UUID) throws {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { throw WebsiteLearningError.notFound }
        var next = self; next.routes.remove(at: index); try commit(next)
    }
    public mutating func clear() { routes = []; revision = UUID() }

    private mutating func commit(_ proposed: Self) throws {
        var proposed = proposed; proposed.revision = UUID(); try proposed.validate(); self = proposed
    }
    private func validate() throws {
        guard routes.count <= Self.maximumRoutes else { throw WebsiteLearningError.capacityExceeded }
        guard Set(routes.map(\.id)).count == routes.count,
              Set(routes.map { $0.origin.url.absoluteString + "\n" + $0.intent }).count == routes.count else {
            throw WebsiteLearningError.invalidState
        }
        guard try JSONEncoder().encode(self).count <= 2_097_152 else { throw WebsiteLearningError.capacityExceeded }
    }
    private enum CodingKeys: String, CodingKey { case routes, revision }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routes = try c.decode([WebRoute].self, forKey: .routes); revision = try c.decode(UUID.self, forKey: .revision)
        try validate()
    }
}
