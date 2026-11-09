import Foundation

public enum WebRouteStepKind: String, Codable, Sendable { case navigate, observe }

/// An observed successful URL load/read, NOT a requested action or inferred link.
/// Runtime supplies the final loaded URL; scripts, selectors, form values and clicks
/// have no representation in this format. A find operation records only an observation.
public struct WebRouteStep: Codable, Equatable, Sendable {
    public let kind: WebRouteStepKind
    public let evidence: WebsiteLessonEvidence
    public var url: URL { evidence.sourceURL }

    public init(kind: WebRouteStepKind, snapshot: PageSnapshot, evidenceQuote: String) throws {
        self.kind = kind; evidence = try WebsiteLessonEvidence(snapshot: snapshot, quote: evidenceQuote)
    }
    var hashFields: [String] { [kind.rawValue] + evidence.hashFields }
}

public struct WebRoute: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let origin: WebsiteOrigin
    /// Normalized matching/deduplication key; never use as the replay instruction.
    public let intent: String
    /// Exact saved user goal, including case-sensitive literals and whitespace.
    /// Legacy records can only fall back to their already-normalized intent.
    public let originalGoal: String
    public let steps: [WebRouteStep]
    public let task: WebTaskEvidence
    public private(set) var successes: Int
    public private(set) var consecutiveMisses: Int
    public private(set) var missStep: Int?
    public private(set) var disabled: Bool
    public let createdAt: Date
    public private(set) var lastUsedAt: Date
    public var contentHash: String {
        WebsiteLearningSafety.fingerprint([id.uuidString, origin.url.absoluteString, intent, originalGoal,
            String(successes), String(consecutiveMisses), missStep.map(String.init) ?? "", String(disabled),
            WebsiteLearningSafety.dateKey(createdAt), WebsiteLearningSafety.dateKey(lastUsedAt)]
            + task.hashFields + steps.flatMap(\.hashFields))
    }

    init(id: UUID = UUID(), intent: String, originalGoal: String? = nil, steps: [WebRouteStep], task: WebTaskEvidence,
         successes: Int = 1, consecutiveMisses: Int = 0, missStep: Int? = nil,
         disabled: Bool = false, createdAt: Date? = nil, lastUsedAt: Date? = nil) throws {
        guard let first = steps.first, steps.count <= WebRouteState.maximumSteps else {
            throw WebsiteLearningError.invalidEvidence
        }
        guard task.isEligible else { throw WebsiteLearningError.ineligibleTask }
        self.id = id; origin = first.evidence.origin
        self.originalGoal = try WebsiteLearningSafety.originalGoal(originalGoal ?? intent)
        self.intent = try WebsiteLearningSafety.intent(self.originalGoal)
        if originalGoal != nil, intent != self.intent { throw WebsiteLearningError.invalidState }
        self.steps = steps; self.task = task
        self.successes = successes; self.consecutiveMisses = consecutiveMisses; self.missStep = missStep
        self.disabled = disabled; self.createdAt = createdAt ?? task.completedAt
        self.lastUsedAt = lastUsedAt ?? task.completedAt
        guard steps.allSatisfy({ $0.evidence.origin == origin }) else { throw WebsiteLearningError.originMismatch }
        guard zip(steps, steps.dropFirst()).allSatisfy({
            $1.kind == .navigate || $0.url == $1.url
        }) else { throw WebsiteLearningError.invalidEvidence }
        guard steps.allSatisfy({ $0.evidence.capturedAt <= task.completedAt }),
              zip(steps, steps.dropFirst()).allSatisfy({ $0.evidence.capturedAt <= $1.evidence.capturedAt }),
              WebsiteLearningSafety.validDate(self.createdAt), WebsiteLearningSafety.validDate(self.lastUsedAt),
              self.createdAt <= self.lastUsedAt, task.completedAt <= self.lastUsedAt,
              (1...1_000_000).contains(successes), (0...1_000_000).contains(consecutiveMisses),
              (consecutiveMisses == 0) == (missStep == nil),
              missStep.map({ steps.indices.contains($0) }) ?? true,
              consecutiveMisses < 2 || disabled else { throw WebsiteLearningError.invalidState }
        guard try JSONEncoder().encode(self).count <= 65_536 else { throw WebsiteLearningError.capacityExceeded }
    }

    mutating func note(_ result: WebRouteReplayResult) throws {
        switch result {
        case .succeeded(let observedSteps, let evidence):
            guard evidence.isEligible, observedSteps.count == steps.count else { throw WebsiteLearningError.ineligibleTask }
            guard zip(steps, observedSteps).allSatisfy({
                $0.kind == $1.kind && $0.url == $1.url && $0.evidence.quote == $1.evidence.quote
            }) else {
                throw WebsiteLearningError.invalidEvidence
            }
            guard observedSteps.allSatisfy({ $0.evidence.capturedAt > lastUsedAt && $0.evidence.capturedAt <= evidence.completedAt }),
                  zip(observedSteps, observedSteps.dropFirst()).allSatisfy({ $0.evidence.capturedAt <= $1.evidence.capturedAt }),
                  evidence.completedAt > lastUsedAt else { throw WebsiteLearningError.invalidEvidence }
            successes = min(1_000_000, successes + 1); consecutiveMisses = 0; missStep = nil
            // A result never silently re-enables a previously disabled route.
            lastUsedAt = evidence.completedAt
        case .diverged(let stepIndex, let at):
            guard steps.indices.contains(stepIndex), WebsiteLearningSafety.validDate(at), at >= lastUsedAt else {
                throw WebsiteLearningError.invalidEvidence
            }
            consecutiveMisses = missStep == stepIndex ? min(1_000_000, consecutiveMisses + 1) : 1
            missStep = stepIndex; disabled = disabled || consecutiveMisses >= 2; lastUsedAt = at
        case .cancelled, .awaitingApproval:
            // Neither cancellation nor a confirmation gate is evidence of failure/success.
            break
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, origin, intent, originalGoal, steps, task, successes, consecutiveMisses, missStep, disabled, createdAt, lastUsedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), intent: c.decode(String.self, forKey: .intent),
                      originalGoal: c.contains(.originalGoal) ? c.decode(String.self, forKey: .originalGoal) : nil,
                      steps: c.decode([WebRouteStep].self, forKey: .steps), task: c.decode(WebTaskEvidence.self, forKey: .task),
                      successes: c.decode(Int.self, forKey: .successes), consecutiveMisses: c.decode(Int.self, forKey: .consecutiveMisses),
                      missStep: c.decodeIfPresent(Int.self, forKey: .missStep), disabled: c.decode(Bool.self, forKey: .disabled),
                      createdAt: c.decode(Date.self, forKey: .createdAt), lastUsedAt: c.decode(Date.self, forKey: .lastUsedAt))
        guard try c.decode(WebsiteOrigin.self, forKey: .origin) == origin else { throw WebsiteLearningError.originMismatch }
    }
}

public enum WebRouteReplayResult: Equatable, Sendable {
    case succeeded(observedSteps: [WebRouteStep], task: WebTaskEvidence)
    case diverged(stepIndex: Int, at: Date)
    case cancelled
    case awaitingApproval
}

/// Non-executable reference data. The host must obtain explicit confirmation, revalidate
/// every URL/redirect/DNS destination and verify the quote against a FRESH observation.
/// No stored route or boolean can authorize a click, input, submission or privileged action.
public struct WebRouteReplayPlan: Equatable, Sendable {
    public let routeID: UUID
    public let contentHash: String
    public let origin: WebsiteOrigin
    public let steps: [WebRouteStep]
    public var requiresUserConfirmation: Bool { true }
    public var requiresPolicyValidationPerStep: Bool { true }
}
