import CryptoKit
import Foundation
#if !SKILL_CATALOG_SMOKE && !SKILLS_CORE_SMOKE
import XCTest
@testable import AssistantSkills
#endif

/// Identical checks run via XCTest and the local CLT executable. No model,
/// network, shell, imported script or endpoint is exercised by this fixture.
enum SkillCatalogFixtures {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Checks {
        var count = 0
        mutating func expect(_ condition: Bool, _ label: String) throws {
            count += 1
            if !condition { throw Failure(description: label) }
        }
        mutating func rejects(_ expected: SkillCatalogError, _ label: String,
                              _ operation: () throws -> Void) throws {
            count += 1
            do { try operation() }
            catch let error as SkillCatalogError where error == expected { return }
            catch { throw Failure(description: label + ": wrong error") }
            throw Failure(description: label + ": did not reject")
        }
    }

    static func run(data: Data) throws -> Int {
        var checks = Checks()
        let catalog = try BundledSkillCatalog.load(data: data)
        let expectedIDs = ["configure-mika", "content-transcribe", "documents", "info-research", "messaging", "skill-authoring"]
        try checks.expect(catalog.entries.map(\.id) == expectedIDs, "all six pinned original skills and order")
        try checks.expect(BundledSkillCatalog.pinnedCommit == "0c172724f3f0c96f7345262588072f6e95db1138", "pinned source commit")
        try checks.expect(catalog.search(" \n").count == 6, "empty search lists all")
        try checks.expect(catalog.search("pypdf").map(\.id) == ["documents"], "supporting script full text searchable")
        try checks.expect(catalog.search("PyPdF").map(\.id) == ["documents"], "search case insensitive")
        try checks.expect(catalog.search("pypdf transcript").isEmpty, "all search terms required")
        try checks.expect(catalog.search("no-such-catalog-phrase").isEmpty, "no fabricated search matches")
        try checks.expect(catalog.entry(id: "missing") == nil, "unknown entry absent")

        let prefix = "core/src/main/resources/skills/"
        let hashes = [
            "LICENSE": "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
            "NOTICE": "7d49ef5ff477ad1a79db8050c7242498a03874e9ac70e7c8f741baeea6a33f24",
            prefix + "configure-mika/SKILL.md": "25560ad126c10263f0c341dd5d25d5e12fe4335a372abe7b8d08895725d97c4f",
            prefix + "content-transcribe/SKILL.md": "fa46715f63de39a274d877f4cc5ec347fb639d7a5bb9aeb8f8b0f81fcf352326",
            prefix + "content-transcribe/references/transcript-output-formats.md": "bbd7bb15518ecf353d1b26ed8c25a24ee471d0bc7a6dc510b8f8a6153d2dc9e8",
            prefix + "documents/SKILL.md": "f5cfa97a04bab6fcbfba4b654c9a59018dd339eea83b260ace47928e3abf230c",
            prefix + "documents/scripts/extract_pdf.py": "41c2e2b51cd23173e0891084d0cd93d54e300e5fd571876740de36ac5968817c",
            prefix + "documents/scripts/manifest.json": "010bf7bf1102f06e20b29b8b63e0ceedf5b7e6856cb76f67ae8f9e2fa74515cf",
            prefix + "info-research/SKILL.md": "75f1bd627136a4e022625f7701fef19f07665b0b52718e0f524997cbf61129c2",
            prefix + "messaging/SKILL.md": "030ef07f6708cea769889a039ee7fcaf8ec3d036032692b83006dc84d99886c9",
            prefix + "skill-authoring/SKILL.md": "2ca1e847565726ec25b55908e3ecd00d1750664638f8c327d699234ecea37a42"
        ]
        let originals = [catalog.license, catalog.notice] + catalog.entries.flatMap { [$0.original] + $0.assets }
        try checks.expect(originals.count == hashes.count, "all eleven files retained")
        for document in originals {
            let hash = SHA256.hash(data: Data(document.content.utf8)).map { String(format: "%02x", $0) }.joined()
            try checks.expect(hash == hashes[document.path], "exact pinned upstream file bytes: " + document.path)
            try checks.expect(document.sha256 == hash, "provenance hash not a placeholder")
            try checks.expect(document.content.hasSuffix("\n"), "original final newline retained")
            try checks.expect(!document.executable, "all original documents and scripts inert")
            try checks.expect(document.sourceURL.host == "github.com" && document.sourceURL.path.hasSuffix(document.path), "source URL pinned public provenance")
        }
        try checks.expect(catalog.license.content.contains("END OF TERMS AND CONDITIONS"), "full Apache license not summary")
        try checks.expect(catalog.notice.content == "Mika\nCopyright 2026 wangzan101\n", "full original NOTICE")
        try checks.expect(catalog.entries.flatMap(\.assets).count == 3, "three supporting resources")

        let required: [String: Set<SkillCatalogRequirement>] = [
            "configure-mika": [.settingsAutomation, .androidControl],
            "content-transcribe": [.legacyWebTools, .workspaceFiles, .androidControl],
            "documents": [.python, .shell, .workspaceFiles, .fileExport],
            "info-research": [.legacyWebTools, .crossOriginResearch, .androidControl],
            "messaging": [.androidControl, .accountAccess, .externalSend],
            "skill-authoring": [.skillMutationTools, .androidControl]
        ]
        var state = SkillsState()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        for entry in catalog.entries {
            try checks.expect(!entry.originalExecutionSupported, "no unsupported original declared ready")
            try checks.expect(Set(entry.requirements) == required[entry.id], "explicit required capability gaps")
            try checks.expect(entry.readiness.contains("未完整支援"), "honest readiness")
            let document = try SkillDocument.parse(entry.adaptationMarkdown, availableToolNames: [])
            try checks.expect(document.name == entry.adaptationName, "separate iOS identity")
            try checks.expect(document.referencedToolNames.isEmpty, "text-only adaptation grants no tool")
            try checks.expect(entry.adaptationMarkdown.contains("not execution parity"), "prominent modification metadata")
            try checks.expect(entry.adaptationMarkdown.contains("Copyright 2026 wangzan101"), "retained attribution in imported copy")
            try checks.expect(entry.adaptationMarkdown.contains(BundledSkillCatalog.pinnedCommit), "imported copy pinned provenance")
            try checks.expect(entry.adaptationMarkdown.contains("Apache-2.0"), "license retained in adaptation")
            try checks.expect(entry.adaptationMarkdown != entry.original.content, "original and adaptation distinct")
            try checks.expect(catalog.search(entry.id).contains { $0.id == entry.id }, "source id searchable")
            try checks.expect(catalog.search(entry.aliases[0]).contains { $0.id == entry.id }, "localized aliases searchable")
            let draft = try catalog.stageAdaptation(id: entry.id, into: &state, now: fixedNow)
            try checks.expect(draft.source == .imported && draft.createdAt == fixedNow, "import provenance and time accurate")
            try checks.expect(draft.document.frontMatter["learned_from"] == nil, "not falsely learned from successful run")
            try checks.expect(draft.document.frontMatter["source"] == .string("imported"), "trusted source imported")
            try checks.expect(state.installed.isEmpty && state.revisions.isEmpty, "staging never approves or marks successful")
            try checks.expect(state.instructionContext(query: entry.adaptationName, availableToolNames: []).text.isEmpty,
                              "pending text never enters model context")
            let before = state
            try checks.rejects(.alreadyAdded, "duplicate pending") { _ = try catalog.stageAdaptation(id: entry.id, into: &state) }
            try checks.expect(state == before, "duplicate rejection atomic")
        }
        try checks.expect(state.pending.count == 6, "six drafts staged")
        let pendingReload = try JSONDecoder().decode(SkillsState.self, from: JSONEncoder().encode(state))
        try checks.expect(pendingReload == state && pendingReload.installed.isEmpty, "pending survives encrypted snapshot Codable without enabling")
        for entry in catalog.entries {
            guard let draft = state.pending.first(where: { $0.name == entry.adaptationName }) else {
                throw Failure(description: "expected pending draft")
            }
            let skill = try state.approveDraft(id: draft.id, availableToolNames: [], now: fixedNow)
            try checks.expect(skill.status == .trial && skill.outcomes.isEmpty, "approval is trial not verified")
            try checks.expect(skill.isEnabled && skill.source == .imported, "explicit approval enables text guidance only")
            let context = state.instructionContext(query: entry.adaptationName, availableToolNames: [])
            try checks.expect(context.skillNames.contains(entry.adaptationName), "approved skill discovered by existing retrieval")
            try checks.expect(context.text.contains("grant no authorization"), "no-dispatch boundary retained")
            try checks.expect(context.text.contains("not execution parity"), "model sees adaptation limits")
            let before = state
            try checks.rejects(.alreadyAdded, "never overwrite existing approved edits") { _ = try catalog.stageAdaptation(id: entry.id, into: &state) }
            try checks.expect(state == before, "approved duplicate rejection atomic")
            try state.suspend(name: skill.name)
            try checks.expect(!state.instructionContext(query: entry.adaptationName, availableToolNames: []).skillNames.contains(skill.name), "suspended catalog skill excluded")
            try state.resume(name: skill.name)
            try checks.expect(state.installed.first { $0.name == skill.name }?.status == .trial, "resume does not fabricate verification")
        }
        try checks.expect(state.pending.isEmpty && state.installed.count == 6, "explicitly approved six")
        try checks.expect(try JSONDecoder().decode(SkillsState.self, from: JSONEncoder().encode(state)) == state, "approved state roundtrip")
        let before = state
        try checks.rejects(.notFound, "unknown entry cannot mutate") { _ = try catalog.stageAdaptation(id: "missing", into: &state) }
        try checks.expect(state == before, "unknown import atomic")
        // Reject then import again is an intentional new review, never activation.
        var rejected = SkillsState()
        let first = try catalog.stageAdaptation(id: "documents", into: &rejected)
        try rejected.rejectDraft(id: first.id)
        _ = try catalog.stageAdaptation(id: "documents", into: &rejected)
        try checks.expect(rejected.pending.count == 1 && rejected.installed.isEmpty, "reimport after rejection requires review again")

        var altered = data
        altered[altered.startIndex] = 91
        for bytes in [Data(), Data("{}".utf8), altered, data + Data(" ".utf8), Data(repeating: 32, count: 256 * 1024 + 1)] {
            try checks.rejects(.invalidCatalog, "invalid or modified immutable archive") { _ = try BundledSkillCatalog.load(data: bytes) }
        }
        let replacements = [
            ("Copyright 2026 wangzan101", "Copyright 2026 someoneelse"),
            ("0c172724f3f0c96f7345262588072f6e95db1138", "0000000000000000000000000000000000000000"),
            ("Python", "SECRET"),
            ("ios-mika-documents", "ios-evil-documents")
        ]
        let source = String(decoding: data, as: UTF8.self)
        for (old, new) in replacements {
            try checks.expect(source.contains(old), "tamper fixture actually changes bytes")
            let bytes = Data(source.replacingOccurrences(of: old, with: new).utf8)
            try checks.rejects(.invalidCatalog, "tampered source/adaptation/provenance fails closed") { _ = try BundledSkillCatalog.load(data: bytes) }
        }
        return checks.count
    }
}

#if SKILL_CATALOG_SMOKE
@main
struct SkillCatalogStandalone {
    static func main() throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.count == 2 else { throw SkillCatalogFixtures.Failure(description: "requires catalog resource path") }
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        print("PASS bundled Skills catalog: \(try SkillCatalogFixtures.run(data: data)) assertions")
    }
}
#elseif !SKILLS_CORE_SMOKE
final class SkillCatalogTests: XCTestCase {
    func testCompletePinnedArchiveAndApprovalLifecycle() throws {
        // Public loader exercises actual packaged Bundle.module, not a fixture copy.
        let catalog = try BundledSkillCatalog.bundled()
        XCTAssertEqual(catalog.entries.count, 6)
        XCTAssertGreaterThan(try SkillCatalogFixtures.run(data: BundledSkillCatalog.bundledData()), 200)
    }
}
#endif
