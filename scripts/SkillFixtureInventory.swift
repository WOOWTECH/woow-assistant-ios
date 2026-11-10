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
        guard baselines.count <= 16, Set(baselines.map(\.namespace)).count == baselines.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var entries: [Entry] = []
        for baseline in baselines {
            guard baseline.version == 1, ["created", "existing"].contains(baseline.phase),
                  let namespace = UUID(uuidString: baseline.namespace), namespace.uuidString == baseline.namespace else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let current = SkillExecutionUITestSupport.fixtureEvidence(
                in: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true), namespace: namespace)
            let comparable = current.status == "valid" && baseline.evidence.status == "valid"
            entries.append(Entry(baseline: baseline, current: current,
                sameHash: comparable ? current.sha256 == baseline.evidence.sha256 : nil,
                sameSize: comparable ? current.bytes == baseline.evidence.bytes : nil,
                sameIdentity: comparable ? current.device == baseline.evidence.device && current.inode == baseline.evidence.inode : nil))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Report(entries: entries)).write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
    }
}
