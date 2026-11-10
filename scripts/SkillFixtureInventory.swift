import Foundation

/// Host-only post-test inventory. The caller resolves the tested simulator's App
/// container; the shared DEBUG reader constructs only recorded UUID PDF names.
@main
struct SkillFixtureInventory {
    struct Entry: Encodable {
        let baseline: SkillExecutionUITestSupport.FixtureBaseline
        let current: SkillExecutionUITestSupport.FixtureEvidence
        let sameHash: Bool?
        let sameSize: Bool?
        let sameIdentity: Bool?
        let currentLocation: SkillExecutionUITestSupport.FixtureLocation?
        let sameSourceURL: Bool?
        let sameParentIdentity: Bool?
    }
    struct Report: Encodable {
        let version = 1
        let observation = "post-test-only"
        let provesPresenceAtEarlierPickerFailure = false
        let entries: [Entry]
    }

    static func main() throws {
        guard CommandLine.arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
        let input = URL(fileURLWithPath: CommandLine.arguments[2])
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 65_537) ?? Data()
        guard bytes.count <= 65_536 else { throw CocoaError(.fileReadTooLarge) }
        let baselines = try JSONDecoder().decode([SkillExecutionUITestSupport.FixtureBaseline].self, from: bytes)
        guard baselines.count <= 64, Set(baselines.map(\.namespace)).count <= 16 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var entries: [Entry] = []
        var keys = Set<String>()
        var currentPairs: [String: (SkillExecutionUITestSupport.FixtureEvidence, SkillExecutionUITestSupport.FixtureLocation?)] = [:]
        for baseline in baselines {
            guard let namespace = UUID(uuidString: baseline.namespace), namespace.uuidString == baseline.namespace else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let current: SkillExecutionUITestSupport.FixtureEvidence
            var location: SkillExecutionUITestSupport.FixtureLocation?
            if baseline.version == 1 {
                guard ["created", "existing"].contains(baseline.phase), baseline.role == nil,
                      baseline.ordinal == nil, baseline.location == nil, keys.insert(baseline.namespace).inserted else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                current = SkillExecutionUITestSupport.fixtureEvidence(in: directory, namespace: namespace)
            } else if baseline.version == 2 {
                guard let role = baseline.role, ["A", "B"].contains(role), let ordinal = baseline.ordinal,
                      let originalLocation = baseline.location, originalLocation.urlSHA256.count == 64,
                      originalLocation.urlSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
                      (["created", "existing"].contains(baseline.phase) && ordinal == 0)
                        || (["prePicker", "selectionReturned", "selectionFailure", "cancelled"].contains(baseline.phase)
                            && (1...3).contains(ordinal)),
                      keys.insert("\(baseline.namespace):\(role):\(baseline.phase):\(ordinal)").inserted else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let sourceKey = baseline.namespace + ":" + role
                if currentPairs[sourceKey] == nil {
                    currentPairs[sourceKey] = SkillExecutionUITestSupport.pairFixtureSample(
                        in: directory, namespace: namespace, role: role)
                }
                (current, location) = currentPairs[sourceKey]!
            } else { throw CocoaError(.fileReadCorruptFile) }
            let comparable = current.status == "valid" && baseline.evidence.status == "valid"
            entries.append(Entry(baseline: baseline, current: current,
                sameHash: comparable ? current.sha256 == baseline.evidence.sha256 : nil,
                sameSize: comparable ? current.bytes == baseline.evidence.bytes : nil,
                sameIdentity: comparable ? current.device == baseline.evidence.device && current.inode == baseline.evidence.inode : nil,
                currentLocation: location,
                sameSourceURL: location.map { $0.urlSHA256 == baseline.location?.urlSHA256 },
                sameParentIdentity: location?.parentInode != nil && baseline.location?.parentInode != nil
                    ? location?.parentDevice == baseline.location?.parentDevice && location?.parentInode == baseline.location?.parentInode : nil))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Report(entries: entries)).write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
    }
}
