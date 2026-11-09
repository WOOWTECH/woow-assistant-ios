// Compile alongside Tests/AssistantMemoryTests/MemoryChecks.swift, linking
// enable-testing AssistantMemory + AssistantModels modules. No XCTest or network.
import Foundation

@main enum MemoryCoreChecks {
    static func main() async {
        do {
            var total = 0
            let mutations = try MemoryChecks.mutations(); total += mutations
            print("mutations: \(mutations)")
            let safety = try MemoryChecks.sensitiveAndCapacity(); total += safety
            print("safety/capacity: \(safety)")
            let retrieval = try MemoryChecks.retrieval(); total += retrieval
            print("retrieval: \(retrieval)")
            let extraction = try MemoryChecks.extraction(); total += extraction
            print("extraction: \(extraction)")
            let model = try await MemoryChecks.modelBoundary(); total += model
            print("model boundary: \(model)")
            print("PASS \(total) assertions; fake model only; no live requests or persistence")
        } catch let error as MemoryChecks.Failure {
            print("FAIL: \(error.name)"); exit(1)
        } catch {
            print("FAIL: \(type(of: error))"); exit(1)
        }
    }
}
