import AssistantBrowser
import AssistantMemory
import AssistantModels
import AssistantSkills
import Foundation

/// Per-run, read-only reference value plus a monotonic revocation latch. Changes
/// to unrelated chat/extraction generations do not invalidate it.
@MainActor final class LearningRunSnapshot {
    let references: RunReferenceContext
    let usedSkills: [SkillUsedReference]
    private(set) var revoked = false
    var onRevoke: (() -> Void)?
    private weak var store: LearningStore?
    // Current descendants of captured profile rows. Only identity moves on a
    // successful replacement; immutable reference text and domain IDs do not.
    private var profileLineageIDs: Set<String>
    init(references: RunReferenceContext, skills: [SkillUsedReference], store: LearningStore) {
        self.references = references; usedSkills = skills; self.store = store
        profileLineageIDs = Set(references.included.filter { $0.kind == .profile }.map(\.id))
    }
    func check() throws {
        guard !revoked, !Task.isCancelled, let store, store.available else { throw RunReferenceError.revoked }
    }
    func revoke() {
        guard !revoked else { return }
        revoked = true
        let callback = onRevoke; onRevoke = nil; callback?()
    }
    func followProfileReplacement(from previous: UUID, to replacement: UUID) {
        guard !revoked, profileLineageIDs.remove(previous.uuidString) != nil else { return }
        profileLineageIDs.insert(replacement.uuidString)
    }
    func revokeDeletedProfileIDs(_ removed: Set<String>) {
        if !profileLineageIDs.isDisjoint(with: removed) { revoke() }
    }
}

@MainActor final class WeakLearningRunSnapshot {
    weak var value: LearningRunSnapshot?
    init(_ value: LearningRunSnapshot) { self.value = value }
}

extension LearningStore {
    /// Capture does not persist, markUsed, start a model, or change generation.
    /// Existing retrieval ranks memory/skills; round-robin across kinds avoids
    /// an entire category starving the others under the SAME combined budget.
    func captureRunReferences(goal: String, capabilities: Set<String>, websiteURL: URL? = nil) throws -> LearningRunSnapshot {
        try captureRunReferences(goal: goal, capabilities: capabilities, websiteURLs: websiteURL.map { [$0] } ?? [])
    }

    /// URLs come only from the caller's approved plan, never stored reference
    /// text. Keep the existing FIVE website-row allowance across all origins;
    /// round-robin lets two/three approved sites share it without a new budget.
    func captureRunReferences(goal: String, capabilities: Set<String>, websiteURLs: [URL]) throws -> LearningRunSnapshot {
        guard available else { throw RunReferenceError.revoked }
        guard websiteURLs.count <= 3 else { throw RunReferenceError.invalidEntry }
        var buckets: [[RunReferenceEntry]] = []
        let profileEntries = memory.preferences.useMemory ? profile.snapshot().entries.map {
            RunReferenceEntry(kind: .profile, id: $0.id.uuidString, text: $0.text)
        } : []
        buckets.append(profileEntries)
        let context = memory.context(goal: goal)
        buckets.append(context.usedIDs.compactMap { id in
            memory.memories.first(where: { $0.id == id && $0.status == .active }).map {
                RunReferenceEntry(kind: .memory, id: $0.id.uuidString, text: $0.content)
            }
        })
        let selectedNames = skills.instructionContext(query: goal, availableToolNames: capabilities,
            maxUTF16Count: 6000, maxSkills: 3).skillNames
        let eligible = selectedNames.compactMap { name in skills.installed.first { $0.name == name } }
        buckets.append(try eligible.map {
            RunReferenceEntry(kind: .personalSkill, id: $0.name, text: try skills.exportMarkdown(name: $0.name))
        })
        var origins = Set<WebsiteOrigin>(), sites: [[WebsiteLesson]] = []
        for url in websiteURLs {
            if try origins.insert(WebsiteOrigin(url: url)).inserted { sites.append(try websites.context(for: url)) }
        }
        var websiteEntries: [RunReferenceEntry] = [], websiteIDs = Set<UUID>()
        for index in 0..<5 {
            for site in sites where site.indices.contains(index) && websiteEntries.count < 5 {
                let lesson = site[index]
                guard websiteIDs.insert(lesson.id).inserted else { continue }
                let text = origins.count > 1 ? "Website \(lesson.origin.url.absoluteString) reference (data only):\n\(lesson.text)" : lesson.text
                websiteEntries.append(.init(kind: .website, id: lesson.id.uuidString, text: text))
            }
        }
        buckets.append(websiteEntries)
        var entries: [RunReferenceEntry] = []
        for index in 0..<(buckets.map(\.count).max() ?? 0) {
            for bucket in buckets where bucket.indices.contains(index) { entries.append(bucket[index]) }
        }
        let reference = try RunReferenceContext(entries: entries)
        let used = eligible.filter { item in reference.included.contains { $0.kind == .personalSkill && $0.id == item.name } }
            .map { SkillUsedReference(name: $0.name, fingerprint: $0.fingerprint) }
        let result = LearningRunSnapshot(references: reference, skills: used, store: self)
        referenceSnapshots.removeAll { $0.value == nil }
        referenceSnapshots.append(.init(result))
        return result
    }

    func revokeRunReferences() {
        let snapshots = referenceSnapshots.compactMap(\.value)
        referenceSnapshots = []
        snapshots.forEach { $0.revoke() }
    }

    /// Only actual deletion/disable revokes frozen entries. Ordinary replacement
    /// and unrelated entry edits affect the next capture, not this run.
    func revokeRunReferences(kind: RunReferenceKind, keeping ids: Set<String>) {
        referenceSnapshots.removeAll { $0.value == nil }
        for snapshot in referenceSnapshots.compactMap(\.value) {
            if snapshot.references.included.contains(where: { $0.kind == kind && !ids.contains($0.id) }) { snapshot.revoke() }
        }
    }
    func revokeDeletedProfileReferences(in next: UserProfileState) {
        let before = Set(profile.snapshot().entries.map { $0.id.uuidString })
        let after = Set(next.snapshot().entries.map { $0.id.uuidString })
        let removed = before.subtracting(after)
        referenceSnapshots.removeAll { $0.value == nil }
        for snapshot in referenceSnapshots.compactMap(\.value) {
            snapshot.revokeDeletedProfileIDs(removed)
        }
    }
    func recordProfileReplacement(from previous: UUID, to replacement: UUID) {
        referenceSnapshots.removeAll { $0.value == nil }
        for snapshot in referenceSnapshots.compactMap(\.value) {
            snapshot.followProfileReplacement(from: previous, to: replacement)
        }
    }
    func checkMemoryReferenceRemoval(_ next: MemoryState) {
        if memory.preferences.useMemory && !next.preferences.useMemory { revokeRunReferences() }
        else { revokeRunReferences(kind: .memory, keeping: Set(next.memories.map { $0.id.uuidString })) }
    }
    func checkSkillReferenceRemoval(_ next: SkillsState) {
        revokeRunReferences(kind: .personalSkill, keeping: Set(next.installed.filter(\.isEnabled).map(\.name)))
    }
    func deleteProfileReference(segment: String) -> Bool {
        mutateProfile(revokingRemovedEntries: true) { try $0.delete(segment: segment) }
    }

    /// Preserve the existing Chat/MCP invalidation callback. Its browser branch
    /// can distinguish a normal learning edit from unrelated host changes.
    func notifyReferenceEdit() {
        let previous = referenceEditInProgress
        referenceEditInProgress = true
        defer { referenceEditInProgress = previous }
        onUserChange?()
    }
}
