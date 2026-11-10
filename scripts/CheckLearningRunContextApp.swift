#if LEARNING_RUN_APP_STANDALONE || canImport(WoowAssistant)
import AssistantBrowser
import AssistantMemory
import AssistantModels
import AssistantPersistence
import AssistantSkills
import Foundation
import WebKit
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
#if !LEARNING_RUN_APP_STANDALONE
import XCTest
@testable import WoowAssistant
#endif

private final class RunReferenceKeys: LearningKeyStore {
    var keys: [String: Data] = [:]
    var unavailable = false
    func read(id: String) throws -> Data? { if unavailable { throw LearningFileError.unavailable }; return keys[id] }
    func insert(_ key: Data, id: String) throws { if unavailable { throw LearningFileError.unavailable }; keys[id] = key }
    func remove(id: String) throws { keys.removeValue(forKey: id) }
    func removeAll(except id: String) throws { keys = keys.filter { $0.key == id } }
}
private final class RunReferenceCredentials: ModelCredentialStoring {
    private var values: [String:String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func insert(_ key: String, account: String) throws { values[account] = key }
    func remove(account: String) throws { values.removeValue(forKey:account) }
    func removeAll() throws { values = [:] }
}
private actor ReferenceModel: ChatModelClient {
    let reply: String
    let gate: ReferenceGate?
    private(set) var requests: [[ModelMessage]] = []
    private(set) var responses = 0
    init(_ reply: String = #"{"action":"finish","answer":"OBSERVED answer"}"#, gate: ReferenceGate? = nil) { self.reply = reply; self.gate = gate }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        requests.append(messages); if let gate { await gate.wait() }; responses += 1; return reply
    }
}
private actor ReferenceGate {
    var open = false; var waiter: CheckedContinuation<Void,Never>?
    func wait() async { await withCheckedContinuation { if open { $0.resume() } else { waiter = $0 } } }
    func release() { open = true; let w = waiter; waiter = nil; w?.resume() }
}
private actor ReferenceBrowser: WebResearchExecuting {
    private(set) var opens = 0, reads = 0
    func inspect() async throws -> WebObservation { reads += 1; return .init(url:URL(string:"https://reference.example/article")!,title:"Synthetic observation",text:"OBSERVED",links:[.init(id:1,title:"next",url:URL(string:"https://reference.example/next")!)]) }
    func openLink(id: Int) async throws -> WebObservation { opens += 1; return try await inspect() }
    func find(text: String) async throws -> WebObservation { try await inspect() }
}

@MainActor enum LearningRunAppChecks {
    struct Failure: Error { let label: String }
    static var counts: [String:Int] = [:]
    static var cancellationProbe: [String:Any] = [:]
    static var group = ""
    static func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw Failure(label:label) }; counts[group,default:0] += 1
    }
    static let configuration = ModelConfiguration(baseURL:URL(string:"https://model.example.invalid/v1")!,model:"synthetic")
    private struct Fixture {
        let root: URL, url: URL, store: LearningStore, keys: RunReferenceKeys
    }
    private static func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-reference-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url = root.appendingPathComponent("learning.vault"), keys = RunReferenceKeys()
        let store = LearningStore(vault:.init(url:url,keys:keys))
        try expect(store.available,"real vault available")
        try expect(store.mutateMemory { _ = try $0.add(kind:.preference,content:"Prefer concise reference answers") },"persist preference")
        try expect(store.mutateProfile { _ = try $0.add(text:"Profile speaks Traditional Chinese") },"persist profile")
        try expect(store.mutateSkills { state in
            let draft = try state.importMarkdown(skill(),availableToolNames:BrowserSession.toolNames)
            _ = try state.approveDraft(id:draft.id,availableToolNames:BrowserSession.toolNames)
        },"actual reviewed skill persisted")
        return .init(root:root,url:url,store:store,keys:keys)
    }
    static func skill() -> String {
        """
        ---
        name: reference-guide
        description: reference research
        ---
        ## 入口
        User selected a reference page.
        ## 步驟
        Use `browser_inspect` only after confirmation.
        ## 容易出錯的地方
        Do not invent sources.
        ## 怎樣算辦成
        Evidence matches observations.
        ## 什麼時候停下交給使用者
        Stop on missing evidence.
        """
    }
    private static func capture(_ f:Fixture) throws -> LearningRunSnapshot {
        try f.store.captureRunReferences(goal:"reference",capabilities:BrowserSession.toolNames)
    }
    static func captureAndNoWrites() throws {
        group="captureAndNoWrites";let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let before=try Data(contentsOf:f.url), revision=f.store.memory.revision, generation=f.store.generation
        let snapshot=try capture(f)
        try expect(snapshot.references.message?.role == "user","one user-role reference")
        try expect(Set(snapshot.references.included.map(\.kind)) == Set([.profile,.memory,.personalSkill]),"three actual reviewed categories")
        try expect(snapshot.usedSkills.count == 1,"only included skill fingerprint tracked")
        try expect(try Data(contentsOf:f.url) == before && f.store.memory.revision == revision && f.store.generation == generation,"capture changes no encrypted bytes/revision/generation")
        try expect(f.store.memory.memories.allSatisfy{$0.useCount == 0},"capture does not markUsed")
        let noTools=try f.store.captureRunReferences(goal:"reference",capabilities:[])
        try expect(noTools.usedSkills.isEmpty && !noTools.references.included.contains{$0.kind == .personalSkill},"runtime capability filter rejects unavailable skill")
        try expect(f.store.updatePreferences{$0.useMemory=false},"master off persisted")
        let disabled=try capture(f)
        try expect(disabled.references.included.allSatisfy{$0.kind == .personalSkill},"skills independent of memory/profile switch")
        try expect(!disabled.references.included.isEmpty,"approved skill still available")
        let reopened=LearningStore(vault:.init(url:f.url,keys:f.keys))
        try expect(reopened.skills.installed.count == 1 && reopened.profile.snapshot().entries.count == 1,"real encrypted reopen retains records")
    }
    static func editsAndUnrelatedGeneration() throws {
        group="editsAndUnrelatedGeneration";let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let snapshot=try capture(f), old=snapshot.references.message
        var normalChanges=0, broadCancellations=0
        f.store.onUserChange={normalChanges += 1;if !f.store.referenceEditInProgress {broadCancellations += 1}}
        let id=f.store.memory.memories[0].id
        try expect(f.store.mutateMemory{_ = try $0.edit(id:id,content:"Edited reference preference")},"normal memory edit")
        try expect(f.store.replaceProfileReference(segment:"Traditional Chinese",replacement:"Japanese"),"normal profile replacement")
        f.store.cancelLearning()
        try snapshot.check()
        try expect(snapshot.references.message == old && !snapshot.revoked,"snapshot frozen across edits and unrelated learning cancellation")
        try expect(normalChanges == 1 && broadCancellations == 0,"ordinary mutation still notifies Chat/MCP without broad browser cancellation")
        let next=try capture(f)
        try expect(next.references.message!.content.contains("Edited reference preference") && next.references.message!.content.contains("Japanese"),"next run receives edited values")
        f.store.resetConversationPresentation()
        try expect(broadCancellations == 1,"unrelated conversation reset retains old host protection")
    }
    static func deletionAndMasterRevocation() throws {
        group="deletionAndMasterRevocation";let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let snapshot=try capture(f);var revoked=0;snapshot.onRevoke={revoked += 1}
        try expect(f.store.mutateMemory{_ = try $0.delete(id:$0.memories[0].id)},"delete captured memory")
        try expect(snapshot.revoked && revoked == 1,"actual captured deletion revokes once")
        snapshot.revoke();try expect(revoked == 1,"revocation latch idempotent")
        let other=try capture(f)
        try expect(f.store.mutateMemory{_ = try $0.add(kind:.fact,content:"Unrelated new memory")},"unrelated row add")
        let unrelated=f.store.memory.memories[0].id
        try expect(f.store.mutateMemory{_ = try $0.delete(id:unrelated)},"unrelated row delete")
        try other.check();try expect(!other.revoked,"unselected deletion leaves frozen run valid")
        try expect(f.store.updatePreferences{$0.useMemory=false},"master off")
        try expect(f.store.updatePreferences{$0.useMemory=true},"master on")
        try expect(other.revoked,"off/on cannot revive old snapshot")
        let skillSnapshot=try capture(f)
        try expect(f.store.mutateSkills{try $0.suspend(name:"reference-guide")},"disable captured skill")
        try expect(skillSnapshot.revoked,"skill disable revokes")
    }
    static func profileUIAndToolDeletion() throws {
        group="profileUIAndToolDeletion";let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let snapshot=try capture(f)
        try expect(f.store.deleteProfileReference(segment:"Profile speaks Traditional Chinese"),"actual UI deletion adapter")
        try expect(snapshot.revoked,"UI profile deletion revokes captured profile")
        try expect(f.store.mutateProfile{_ = try $0.add(text:"Prefer tea")},"new profile")
        let toolSnapshot=try capture(f), generation=f.store.generation
        let request=try UserProfileToolRequest.parse(#"{"op":"delete","match":"Prefer tea","quote":"Delete Prefer tea"}"#)
        let review=try request.prepare(state:f.store.profile,utterances:["Delete Prefer tea"])
        _ = try f.store.commitProfileTool(review,expectedGeneration:generation)
        try expect(toolSnapshot.revoked && f.store.generation == generation,"real tool delete revokes without changing Chat transaction generation")
    }
    static func profileReplacementThenUnrelatedDelete() throws {
        group="profileReplacementThenUnrelatedDelete"
        let scenarios: [(tools: [Bool], languages: [String])] = [
            ([false], ["Japanese"]), ([true], ["Japanese"]),
            ([false,false], ["Japanese","Korean"]), ([true,true], ["Japanese","Korean"]),
            ([false,true,false], ["Japanese","Korean","French"]),
            ([false], ["Traditional Chinese"]), ([true], ["Traditional Chinese"])
        ]
        for scenario in scenarios { for deleteViaTool in [false,true] {
            let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
            let snapshot=try capture(f),original=snapshot.references.message
            var current="Profile speaks Traditional Chinese", revocations=0
            snapshot.onRevoke={revocations += 1}
            for (viaTool,language) in zip(scenario.tools,scenario.languages) {
                let replacement="Profile speaks " + language
                let previousID=f.store.profile.snapshot().entries[0].id
                if viaTool { try profileTool(f.store,op:"replace",match:current,text:replacement) }
                else {try expect(f.store.replaceProfileReference(segment:current,replacement:replacement,
                    expectedRevision:f.store.profile.revision),"explicit manual replacement persisted")}
                try expect(f.store.profile.snapshot().entries[0].id != previousID,"replace including no-op keeps Mika new-ID semantics")
                try snapshot.check()
                try expect(!snapshot.revoked && snapshot.references.message == original,"replacement keeps ancestor text immutable for this run")
                current=replacement
            }
            try expect(f.store.mutateProfile{_ = try $0.add(text:"Unrelated sentence B")},"add unrelated B after capture")
            if deleteViaTool {try profileTool(f.store,op:"delete",match:"Unrelated sentence B")}
            else {try expect(f.store.deleteProfileReference(segment:"Unrelated sentence B"),"UI deletes unrelated B")}
            try expect(!snapshot.revoked && snapshot.references.message == original,"deleting B must not revoke previously superseded captured A")
            try snapshot.check()
            let fresh=try capture(f)
            if deleteViaTool {try profileTool(f.store,op:"delete",match:current)}
            else {try expect(f.store.deleteProfileReference(segment:current),"delete actually captured replacement")}
            try expect(fresh.revoked,"a run that captured replacement is revoked by its deletion")
            try expect(snapshot.revoked,"deleting replacement must revoke the run that captured its ancestor")
            try expect(revocations == 1 && snapshot.references.message == original,"lineage revokes once without rewriting frozen text")
        }}
        for viaTool in [false,true] {
            let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
            let snapshot=try capture(f),original=f.store.profile,bytes=try Data(contentsOf:f.url)
            f.keys.unavailable=true
            if viaTool {
                do {try profileTool(f.store,op:"replace",match:"Traditional Chinese",text:"Japanese");throw Failure(label:"failed tool replacement published")}
                catch is LearningFileError {}
            } else {try expect(!f.store.replaceProfileReference(segment:"Traditional Chinese",replacement:"Japanese"),"failed manual replacement rejected")}
            try expect(f.store.profile == original && !snapshot.revoked && (try Data(contentsOf:f.url)) == bytes,"failed replacement preserves state, disk and ancestor identity")
            f.keys.unavailable=false
            // Deleting the original after a failed replacement must still revoke.
            try expect(f.store.deleteProfileReference(segment:"Traditional Chinese"),"delete original after failed replacement")
            try expect(snapshot.revoked,"failed write never moves lineage to an unpublished ID")

            try expect(f.store.mutateProfile{_ = try $0.add(text:"Prefer tea")},"fresh profile after failure")
            let second=try capture(f),revision=f.store.profile.revision
            try expect(f.store.replaceProfileReference(segment:"tea",replacement:"coffee",expectedRevision:revision),"replace before failed deletion")
            try expect(!f.store.replaceProfileReference(segment:"coffee",replacement:"cocoa",expectedRevision:revision),"stale manual editor rejected")
            let persisted=try Data(contentsOf:f.url)
            f.keys.unavailable=true
            if viaTool {
                do {try profileTool(f.store,op:"delete",match:"Prefer coffee");throw Failure(label:"failed tool deletion published")}
                catch is LearningFileError {}
            } else {try expect(!f.store.deleteProfileReference(segment:"Prefer coffee"),"failed manual deletion rejected")}
            try expect(!second.revoked && (try Data(contentsOf:f.url)) == persisted,"failed deletion never revokes a valid frozen ancestor")
            f.keys.unavailable=false
            if viaTool {try profileTool(f.store,op:"delete",match:"Prefer coffee")}
            else {try expect(f.store.deleteProfileReference(segment:"Prefer coffee"),"retry as new explicit manual deletion")}
            try expect(second.revoked,"successful later deletion revokes tracked ancestor")
        }
    }
    private static func profileTool(_ store: LearningStore, op: String, match: String, text: String? = nil) throws {
        let quote = op == "replace" ? "Replace \(match) with \(text!)" : "Delete \(match)"
        var args=["op":op,"match":match,"quote":quote]
        if let text {args["text"]=text}
        let raw=String(decoding:try JSONSerialization.data(withJSONObject:args),as:UTF8.self)
        let review=try UserProfileToolRequest.parse(raw).prepare(state:store.profile,utterances:[quote])
        _ = try store.commitProfileTool(review,expectedGeneration:store.generation)
    }
    static func reloadClearAndFailedWrite() throws {
        group="reloadClearAndFailedWrite";let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let snapshot=try capture(f), before=try Data(contentsOf:f.url)
        f.keys.unavailable=true
        try expect(!f.store.mutateMemory{_ = try $0.edit(id:$0.memories[0].id,content:"Must not publish")},"actual key-store failure rejects write")
        try expect(!snapshot.revoked && (try Data(contentsOf:f.url)) == before,"failed ordinary edit neither publishes nor revokes valid snapshot")
        f.store.reload()
        try expect(snapshot.revoked && !f.store.available,"reload/storage unavailable revokes")
        f.keys.unavailable=false;f.store.reload()
        let fresh=try capture(f)
        try expect(f.store.clearAll(),"encrypted clear succeeds")
        try expect(fresh.revoked && f.store.memory.memories.isEmpty && f.store.profile.snapshot().entries.isEmpty,"clear revokes and persists empty values")
    }
    static func maximumLegalCapture() throws {
        group="maximumLegalCapture";let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try expect(f.store.mutateMemory { state in
            for index in 1..<500 { _ = try state.add(kind:.fact,content:"m\(index)") }
        },"persist all 500 legal memory rows in one real transaction")
        try expect(f.store.mutateProfile { state in
            for index in 1..<20 { _ = try state.add(text:"Profile sentence \(index)") }
        },"persist 20 active profile sentences")
        try expect(f.store.mutateSkills { state in
            for index in 1...2 {
                let draft = try state.importMarkdown(skill().replacingOccurrences(of:"reference-guide",with:"reference-guide-\(index)"),availableToolNames:BrowserSession.toolNames)
                _ = try state.approveDraft(id:draft.id,availableToolNames:BrowserSession.toolNames)
            }
        },"persist three reviewed matching skills")
        let url=URL(string:"https://reference.example/article")!
        let evidence=try WebsiteLessonEvidence(snapshot:.init(url:url,title:"Synthetic",visibleText:"Observed evidence",capturedAt:.now),quote:"Observed evidence")
        try expect(f.store.mutateWeb { web,_ in
            for index in 0..<5 { _ = try web.addManual(text:"Website note \(index)",evidence:evidence) }
        },"persist five approved exact-origin website lessons")
        try expect(f.store.memory.context(goal:"reference").usedIDs.count == 500,"real Auto retrieval can select all 500 short active memories")
        let before=try Data(contentsOf:f.url)
        let result=try f.store.captureRunReferences(goal:"reference",capabilities:BrowserSession.toolNames,websiteURL:url)
        try expect(result.references.included.count + result.references.omitted.count == 528,"actual legal 20+500+3+5 capture does not throw")
        try expect(!result.references.omitted.isEmpty && result.references.characterCount <= 6000 && result.references.utf8Count <= 24000,"whole-row omission enforces combined output budget")
        try expect(Set(result.references.included.map(\.kind)) == Set(RunReferenceKind.allCases),"shared budget includes every available reference kind")
        try expect(try Data(contentsOf:f.url) == before,"maximum capture is still read-only")
    }
    static func websiteEditDeleteAndFailure() throws {
        group="websiteEditDeleteAndFailure";let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let url=URL(string:"https://reference.example/article")!
        let evidence=try WebsiteLessonEvidence(snapshot:.init(url:url,title:"Synthetic",visibleText:"Observed evidence",capturedAt:.now),quote:"Observed evidence")
        try expect(f.store.mutateWeb { web,_ in _ = try web.addManual(text:"Original website reference",evidence:evidence) },"persist website lesson")
        let id=f.store.websites.lessons[0].id
        let snapshot=try f.store.captureRunReferences(goal:"reference",capabilities:BrowserSession.toolNames,websiteURL:url)
        let wrongOrigin=try f.store.captureRunReferences(goal:"reference",capabilities:BrowserSession.toolNames,websiteURL:URL(string:"https://other.example/")!)
        try expect(!wrongOrigin.references.included.contains{$0.kind == .website},"website references remain exact-origin")
        var edits=0,broad=0
        f.store.onUserChange={edits += 1;if !f.store.referenceEditInProgress {broad += 1}}
        try expect(f.store.mutateWeb { web,_ in try web.edit(id:id,text:"Changed website reference",evidence:evidence) },"ordinary website edit succeeds")
        try snapshot.check()
        try expect(edits == 1 && broad == 0 && snapshot.references.message!.content.contains("Original website reference"),"ordinary website edit preserves frozen snapshot without broad cancellation")
        let next=try f.store.captureRunReferences(goal:"reference",capabilities:BrowserSession.toolNames,websiteURL:url)
        try expect(next.references.message!.content.contains("Changed website reference"),"next run receives changed website lesson")
        let before=try Data(contentsOf:f.url)
        f.keys.unavailable=true
        try expect(!f.store.mutateWeb { web,_ in try web.delete(id:id) },"actual failed website persistence rejects deletion")
        try expect(!snapshot.revoked && !next.revoked && broad == 0,"failed write does not revoke existing reference or broadly cancel")
        try expect(try Data(contentsOf:f.url) == before,"failed website deletion leaves encrypted bytes unchanged")
        f.keys.unavailable=false
        try expect(f.store.mutateWeb { web,_ in try web.delete(id:id) },"actual website deletion succeeds")
        try expect(snapshot.revoked && next.revoked && !wrongOrigin.revoked,"deletion revokes only captured website rows")
        try expect(f.store.mutateWeb { web,_ in _ = try web.addManual(text:"New website reference",evidence:evidence) },"new website row")
        let clearSnapshot=try f.store.captureRunReferences(goal:"reference",capabilities:BrowserSession.toolNames,websiteURL:url)
        try expect(f.store.mutateWeb { web,_ in web.clear() },"website clear persisted")
        try expect(clearSnapshot.revoked,"website clear revokes captured row")
    }
    static func actualRunnerAndLateCancellation() async throws {
        group="actualRunnerAndLateCancellation";let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let snapshot=try capture(f), model=ReferenceModel(), browser=ReferenceBrowser()
        let result=try await WebResearchRunner(client:model).run(goal:"Current exact request",browser:browser,configuration:configuration,apiKey:"synthetic",references:snapshot.references,validateContext:{try await snapshot.check()})
        let requests=await model.requests
        try expect(result.answer == "OBSERVED answer" && requests.count == 1,"actual runner consumes real App snapshot")
        try expect(requests[0][1] == snapshot.references.message && requests[0][2].content == "Current exact request","reference before unchanged current request")
        try expect(requests[0].filter{$0.role == "system"}.count == 1,"references never become system messages")
        let gate=ReferenceGate(), late=ReferenceModel(#"{"action":"open","linkID":1}"#,gate:gate), lateBrowser=ReferenceBrowser()
        let task=Task{try await WebResearchRunner(client:late).run(goal:"reference",browser:lateBrowser,configuration:configuration,apiKey:"synthetic",references:snapshot.references,validateContext:{try await snapshot.check()})}
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        while await late.requests.isEmpty,ContinuousClock.now < deadline {try await Task.sleep(nanoseconds:1_000_000)}
        let sent = await late.requests.count
        try expect(sent == 1,"model is actually in flight before revocation")
        _ = f.store.updatePreferences{$0.useMemory=false}
        await gate.release()
        do {_ = try await task.value;throw Failure(label:"late reply must fail")}
        catch let e as RunReferenceError {try expect(e == .revoked,"late response fails exact revocation")}
        let opened = await lateBrowser.opens
        try expect(opened == 0,"late open cannot execute after revocation")
    }
    /// Actual App entry point and real native WebKit DOM, with a local synthetic
    /// document. No browser executor substitute, external page or live model.
    static func actualBrowserSessionReferences(onlyCancelledLink: Bool = false) async throws {
        group="actualBrowserSessionReferences"
        for operation in onlyCancelledLink ? ["cancelledLink"] : ["edit", "masterOff", "clear", "cancel", "cancelledLink"] {
            let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
            let suite="io.woowtech.run-reference-check."+UUID().uuidString
            let defaults=UserDefaults(suiteName:suite)!
            defer{defaults.removePersistentDomain(forName:suite)}
            let repository=ModelSettingsRepository(defaults:defaults,credentials:RunReferenceCredentials())
            _ = try repository.save(baseURL:configuration.baseURL.absoluteString,model:configuration.model,newKey:"synthetic-not-a-key")
            let gate=ReferenceGate(), model=ReferenceModel(gate:gate)
            let chat=ChatSession(learning:f.store,repository:repository,client:model)
            let browser=BrowserSession(dataStore:.nonPersistent())
            let web=browser.webView
            web.frame=CGRect(x:0,y:0,width:700,height:500)
            #if canImport(AppKit)
            let window=NSWindow(contentRect:web.frame,styleMask:[.borderless],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=web;window.orderFront(nil)
            defer{window.close()}
            #else
            guard let scene=UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).first else {throw Failure(label:"hosted UIWindowScene unavailable")}
            let previous=scene.windows.first(where: \.isKeyWindow)
            let window=UIWindow(windowScene:scene),controller=UIViewController()
            window.rootViewController=controller;window.makeKeyAndVisible()
            controller.view.addSubview(web)
            defer{web.removeFromSuperview();window.isHidden=true;window.rootViewController=nil;previous?.makeKey()}
            #endif
            defer{browser.cancel();web.stopLoading()}
            let url=URL(string:"https://research.example.invalid/reference")!
            web.loadHTMLString("<!doctype html><title>Reference native fixture</title><p>ACTUAL_REFERENCE_DOM_ONLY</p><a href='https://research.example.invalid/next'>Observed next link</a>",baseURL:url)
            let loadEnd=ContinuousClock.now.advanced(by:.seconds(75))
            while (browser.current == nil || web.isLoading),ContinuousClock.now < loadEnd {try await Task.sleep(nanoseconds:20_000_000)}
            try expect(browser.current?.url == url && browser.current?.text.contains("ACTUAL_REFERENCE_DOM_ONLY") == true,"actual BrowserSession observed local WebKit document")
            if operation == "cancelledLink" {
                guard let link=browser.current?.links.first else {throw Failure(label:"actual DOM must expose valid link ID")}
                var loadingStarts=0
                let observation=web.observe(\.isLoading,options:[.new]) { _,change in if change.newValue == true {loadingStarts += 1} }
                defer{observation.invalidate()}
                let task=Task { @MainActor in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await browser.openLink(id:link.id)
                }
                do {_ = try await task.value;throw Failure(label:"cancelled valid open must throw")}
                catch is CancellationError {try expect(true,"actual BrowserSession throws cancellation for valid observed link")}
                cancellationProbe=["valid_observed_link_id":link.id,"loading_starts":loadingStarts,
                    "automation_claimed":browser.automationOwnsDocument,"url_changed":web.url != url,
                    "task_cancelled_before_open":true]
                try expect(loadingStarts == 0 && !browser.automationOwnsDocument && web.url == url,"cancelled valid link starts zero navigation and never claims document")
                continue
            }
            browser.goal="reference current user request"
            browser.beginResearch(using:chat)
            let requestEnd=ContinuousClock.now.advanced(by:.seconds(10))
            while await model.requests.isEmpty,ContinuousClock.now < requestEnd {try await Task.sleep(nanoseconds:10_000_000)}
            let requests=await model.requests
            // Always drain a waiting synthetic response even on an assertion failure.
            do {
                try expect(requests.count == 1 && browser.isRunning && browser.hasActiveRunReferences,"actual beginResearch holds frozen references while model is in flight")
                let sent=requests[0]
                try expect(sent[1].role == "user" && sent[1].content.contains("Profile speaks Traditional Chinese") && sent[1].content.contains("Prefer concise reference answers"),"actual App request includes profile and memory as user data")
                try expect(sent[1].content.contains("reference-guide") && sent[2].content == browser.goal && sent.filter{$0.role == "system"}.count == 1,"current request and tool policy retain precedence in actual App request")
                try expect(sent.last?.content.contains("ACTUAL_REFERENCE_DOM_ONLY") == true,"real DOM observation remains separate from saved references")
                switch operation {
                case "edit":
                    try expect(f.store.mutateMemory{_ = try $0.edit(id:$0.memories[0].id,content:"New next-run preference")},"persist ordinary edit during actual request")
                    try expect(browser.isRunning && browser.hasActiveRunReferences,"ordinary edit leaves actual research running")
                case "masterOff":
                    try expect(f.store.updatePreferences{$0.useMemory=false},"master off persisted during actual request")
                case "clear":
                    try expect(f.store.clearAll(),"actual encrypted clear during request")
                default:browser.cancel()
                }
                let bytes=try Data(contentsOf:f.url)
                await gate.release()
                let finishEnd=ContinuousClock.now.advanced(by:.seconds(10))
                while (await model.responses == 0 || browser.isRunning),ContinuousClock.now < finishEnd {try await Task.sleep(nanoseconds:10_000_000)}
                try expect(!browser.isRunning && !browser.hasActiveRunReferences,"actual App task ended and released its snapshot")
                if operation == "edit" {try expect(browser.answer == "OBSERVED answer","normal edit allows original frozen request to finish")}
                else {try expect(browser.answer == nil && browser.status.contains("已停止"),"late model answer cannot publish after actual App revocation/cancel")}
                try expect(try Data(contentsOf:f.url) == bytes,"reference run causes no extra persistence after normal edit or cancellation")
            } catch {await gate.release();throw error}
        }
    }
}
#if LEARNING_RUN_APP_STANDALONE
@main enum LearningRunAppMain {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {try await run();fflush(stdout);exit(0)}
            catch {print(String(decoding:try! JSONSerialization.data(withJSONObject:["failed":1,"failure":(error as? LearningRunAppChecks.Failure)?.label ?? "operation_failed","cancellation_probe":LearningRunAppChecks.cancellationProbe],options:.sortedKeys),as:UTF8.self));fflush(stdout);exit(1)}
        }
        app.run()
    }
    @MainActor static func run() async throws {
        if CommandLine.arguments.contains("--focus-profile-deletion") {
            try LearningRunAppChecks.profileReplacementThenUnrelatedDelete()
            print("PROFILE_DELETION_PASS");return
        }
        if CommandLine.arguments.contains("--focus-cancelled-navigation") {
            try await LearningRunAppChecks.actualBrowserSessionReferences(onlyCancelledLink:true)
            print(String(decoding:try JSONSerialization.data(withJSONObject:LearningRunAppChecks.cancellationProbe,options:.sortedKeys),as:UTF8.self));return
        }
        try LearningRunAppChecks.captureAndNoWrites()
        try LearningRunAppChecks.editsAndUnrelatedGeneration()
        try LearningRunAppChecks.deletionAndMasterRevocation()
        try LearningRunAppChecks.profileUIAndToolDeletion()
        try LearningRunAppChecks.profileReplacementThenUnrelatedDelete()
        try LearningRunAppChecks.reloadClearAndFailedWrite()
        try LearningRunAppChecks.maximumLegalCapture()
        try LearningRunAppChecks.websiteEditDeleteAndFailure()
        try await LearningRunAppChecks.actualRunnerAndLateCancellation()
        try await LearningRunAppChecks.actualBrowserSessionReferences()
        let groups=LearningRunAppChecks.counts
        print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":groups.values.reduce(0,+),"failed":0,"groups":groups,"cancellation_probe":LearningRunAppChecks.cancellationProbe],options:.sortedKeys),as:UTF8.self))
    }
}
#else
final class LearningRunAppIntegrationTests: XCTestCase {
    @MainActor func testCaptureAndNoWrites() throws {try LearningRunAppChecks.captureAndNoWrites()}
    @MainActor func testEditsAndUnrelatedGeneration() throws {try LearningRunAppChecks.editsAndUnrelatedGeneration()}
    @MainActor func testDeletionAndMasterRevocation() throws {try LearningRunAppChecks.deletionAndMasterRevocation()}
    @MainActor func testProfileUIAndToolDeletion() throws {try LearningRunAppChecks.profileUIAndToolDeletion()}
    @MainActor func testProfileReplacementThenUnrelatedDelete() throws {try LearningRunAppChecks.profileReplacementThenUnrelatedDelete()}
    @MainActor func testReloadClearAndFailedWrite() throws {try LearningRunAppChecks.reloadClearAndFailedWrite()}
    @MainActor func testMaximumLegalCapture() throws {try LearningRunAppChecks.maximumLegalCapture()}
    @MainActor func testWebsiteEditDeleteAndFailure() throws {try LearningRunAppChecks.websiteEditDeleteAndFailure()}
    @MainActor func testActualRunnerAndLateCancellation() async throws {try await LearningRunAppChecks.actualRunnerAndLateCancellation()}
    @MainActor func testActualBrowserSessionReferences() async throws {try await LearningRunAppChecks.actualBrowserSessionReferences()}
}
#endif
#endif
