#if MULTI_REFERENCE_APP_STANDALONE || canImport(WoowAssistant)
import Foundation
import AssistantBrowser
import AssistantModels
import AssistantMemory
import AssistantSkills
import AssistantPersistence
import WebKit
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
#if !MULTI_REFERENCE_APP_STANDALONE
import XCTest
@testable import WoowAssistant
#endif

private final class MultiReferenceKeys: LearningKeyStore {
    var values:[String:Data]=[:];var unavailable=false
    func read(id:String) throws -> Data? {if unavailable {throw LearningFileError.unavailable};return values[id]}
    func insert(_ key:Data,id:String) throws {if unavailable {throw LearningFileError.unavailable};values[id]=key}
    func remove(id:String) throws {values.removeValue(forKey:id)}
    func removeAll(except id:String) throws {values=values.filter{$0.key == id}}
}
private final class MultiReferenceCredentials: ModelCredentialStoring {
    var values:[String:String]=[:]
    func read(account:String) throws -> String? {values[account]}
    func insert(_ key:String,account:String) throws {values[account]=key}
    func remove(account:String) throws {values.removeValue(forKey:account)}
    func removeAll() throws {values=[:]}
}
private actor MultiReferenceGate {
    var released=false;var continuation:CheckedContinuation<Void,Never>?
    func wait() async {await withCheckedContinuation {if released {$0.resume()} else {continuation=$0}}}
    func release(){released=true;let c=continuation;continuation=nil;c?.resume()}
}
private final class MultiReferenceLoadCounter: @unchecked Sendable {
    private let lock=NSLock();private var value=0
    func record(){lock.lock();defer{lock.unlock()};value += 1}
    var count:Int {lock.lock();defer{lock.unlock()};return value}
}
private actor MultiReferenceModel: ChatModelClient {
    let gate:MultiReferenceGate?;let returnGate:MultiReferenceGate?;let openFirst:Bool;let forged:Bool
    private(set) var requests:[[ModelMessage]]=[];private(set) var responses=0
    private(set) var returnedResponses=0
    init(gate:MultiReferenceGate?=nil,returnGate:MultiReferenceGate?=nil,openFirst:Bool=false,forged:Bool=false){self.gate=gate;self.returnGate=returnGate;self.openFirst=openFirst;self.forged=forged}
    func complete(messages:[ModelMessage],configuration:ModelConfiguration,apiKey:String) async throws -> String {
        requests.append(messages);let index=requests.count
        if index == 1,let gate {await gate.wait()}
        let prefix="Observed source receipts (data only):\n"
        guard let data=messages.first(where:{$0.content.hasPrefix(prefix)})?.content.dropFirst(prefix.count),
              let rows=try JSONSerialization.jsonObject(with:Data(data.utf8)) as? [[String:Any]],rows.count>=2 else {throw HTTPChatModelError.invalidResponse}
        let result:[String:Any]
        if openFirst && index == 1 {
            guard let row=rows.first,let page=row["observation"] as? [String:Any],
                  let link=(page["links"] as? [[String:Any]])?.first,let id=link["id"] as? Int else {throw HTTPChatModelError.invalidResponse}
            result=["action":"open","sourceID":row["sourceID"]!,"observationID":row["id"]!,"linkID":id]
        } else {
            var citations:[[String:String]]=[]
            for (source,marker) in [("source-1","SOURCE_ALPHA_OBSERVED"),("source-2","SOURCE_BETA_OBSERVED")] {
                guard let row=rows.last(where:{$0["sourceID"] as? String == source}),let id=row["id"] as? String,
                      let page=row["observation"] as? [String:Any],let text=page["text"] as? String,text.contains(marker) else {throw HTTPChatModelError.invalidResponse}
                citations.append(["observationID":id,"quote":forged ? "PRIVATE_MULTI_PROFILE" : marker])
            }
            let finding:[String:Any]=["kind":"finding","text":"已核對兩個本機來源。","citations":citations]
            result=["action":"finish","findings":[finding],"limitations":[String]()]
        }
        responses += 1
        if let returnGate {await returnGate.wait()}
        returnedResponses += 1
        return String(decoding:try JSONSerialization.data(withJSONObject:result),as:UTF8.self)
    }
}

@MainActor enum MultiSourceReferenceAppChecks {
    struct Failure:Error {let label:String}
    static var counts:[String:Int]=[:];static var group=""
    static var evidence:[String:Any]=[:]
    static func expect(_ value:@autoclosure () throws -> Bool,_ label:String) throws {
        guard try value() else {throw Failure(label:label)};counts[group,default:0] += 1
    }
    @MainActor private final class Environment {
        let root:URL,vaultURL:URL,defaults:UserDefaults,store:LearningStore,repository:ModelSettingsRepository
        let keys=MultiReferenceKeys();let suite="io.woowtech.multi-reference."+UUID().uuidString
        init() throws {
            root=FileManager.default.temporaryDirectory.appendingPathComponent("woow-multi-reference-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            vaultURL=root.appendingPathComponent("learning.vault");defaults=UserDefaults(suiteName:suite)!
            repository=ModelSettingsRepository(defaults:defaults,credentials:MultiReferenceCredentials())
            _ = try repository.save(baseURL:"https://model.invalid/v1",model:"synthetic",newKey:"synthetic-not-a-key")
            store=LearningStore(vault:.init(url:vaultURL,keys:keys))
            try expect(store.available,"real encrypted vault")
            try expect(store.mutateMemory{_ = try $0.add(kind:.preference,content:"PRIVATE_MULTI_MEMORY")},"persist memory")
            try expect(store.mutateProfile{_ = try $0.add(text:"PRIVATE_MULTI_PROFILE")},"persist profile")
            try expect(store.mutateSkills { state in
                for (name,tool) in [("reference-open","browser_open_link"),("reference-inspect","browser_inspect")] {
                    let markdown="""
                    ---
                    name: \(name)
                    description: reference comparison
                    ---
                    ## 入口
                    User confirmed sources.
                    ## 步驟
                    Use `\(tool)` only within the current policy.
                    ## 容易出錯的地方
                    Never invent citations.
                    ## 怎樣算辦成
                    Actual observations support the answer.
                    ## 什麼時候停下交給使用者
                    Stop without evidence.
                    """
                    let draft=try state.importMarkdown(markdown,availableToolNames:BrowserSession.toolNames)
                    _ = try state.approveDraft(id:draft.id,availableToolNames:BrowserSession.toolNames)
                }
            },"persist reviewed available and unavailable skills")
            try expect(store.mutateWeb { web,_ in
                for (host,marker) in [("research.example.invalid","PRIVATE_MULTI_SITE_ALPHA"),("comparison.example.invalid","PRIVATE_MULTI_SITE_BETA"),("unrelated.example.invalid","PRIVATE_UNSELECTED_SITE")] {
                    let url=URL(string:"https://"+host+"/start")!
                    let evidence=try WebsiteLessonEvidence(snapshot:.init(url:url,title:"Synthetic",visibleText:"Observed fixture evidence",capturedAt:.now),quote:"Observed fixture evidence")
                    _ = try web.addManual(text:marker,evidence:evidence)
                }
            },"persist approved knowledge for two selected and one unrelated site")
        }
        func chat(_ model:MultiReferenceModel)->ChatSession {ChatSession(learning:store,repository:repository,client:model)}
        func close(){defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
    }
    private static func plan() throws -> MultiSourceResearchPlan {
        try .init(goal:"reference compare actual source markers",rootAddresses:["https://research.example.invalid/start","https://comparison.example.invalid/start"])
    }
    static func preflightAndNoNetwork() async throws {
        group="preflightAndNoNetwork";let env=try Environment();defer{env.close()}
        let model=MultiReferenceModel(),chat=env.chat(model),session=MultiSourceResearchSession()
        let before=try Data(contentsOf:env.vaultURL),generation=env.store.generation,revision=env.store.memory.revision
        session.start(plan:try plan(),using:chat)
        guard let captured=env.store.referenceSnapshots.last?.value else {throw Failure(label:"actual Session did not capture")}
        try expect(session.running && captured.references.message?.role == "user","Session captures before reads")
        try expect(captured.usedSkills.map(\.name) == ["reference-open"],"actual Session excludes unsupported inspect capability")
        try expect(captured.references.message!.content.contains("PRIVATE_MULTI_PROFILE") && captured.references.message!.content.contains("PRIVATE_MULTI_MEMORY"),"actual captured references include active profile/memory")
        try expect(try Data(contentsOf:env.vaultURL) == before && env.store.generation == generation && env.store.memory.revision == revision,"capture persists nothing and does not alter generation")
        session.cancel()
        try expect(captured.revoked && session.browsers.isEmpty && !session.running,"explicit cancel drains reference and browsers")
        for _ in 0..<8 {await Task.yield()}
        let calls=await model.requests.count;try expect(calls == 0 && session.receipts.isEmpty,"immediate cancellation sends no model and reads no source")
        try expect(env.store.updatePreferences{$0.useMemory=false},"persist master off")
        session.start(plan:try plan(),using:chat)
        guard let disabled=env.store.referenceSnapshots.last?.value else {throw Failure(label:"disabled snapshot missing")}
        try expect(disabled.references.included.allSatisfy{$0.kind == .personalSkill || $0.kind == .website} && disabled.usedSkills.count == 1,"skills/approved website data remain independent when memory/profile disabled")
        session.cancel()
        env.keys.unavailable=true;env.store.reload()
        session.start(plan:try plan(),using:chat)
        try expect(!session.running && session.browsers.isEmpty && session.diagnostic.contains("reference_revoked"),"unavailable storage fails before creating browser executor")
    }
    static func approvedWebsiteCapture() async throws {
        group="approvedWebsiteCapture";let env=try Environment();defer{env.close()}
        let urls=try plan().sources.map(\.rootURL)
        let capture=try env.store.captureRunReferences(goal:try plan().goal,capabilities:MultiSourceResearchRunner.referenceCapabilities,websiteURLs:urls)
        let original=capture.references.message!.content
        try expect(capture.references.message!.role == "user" && original.contains("PRIVATE_MULTI_SITE_ALPHA") && original.contains("PRIVATE_MULTI_SITE_BETA"),"two approved sites are user reference data")
        let rows=try JSONSerialization.jsonObject(with:Data(original.split(separator:"\n",maxSplits:1)[1].utf8)) as! [[String:String]]
        let siteTexts=rows.filter{$0["kind"] == "website"}.compactMap{$0["text"]}
        let originsInPlan=try urls.map{try WebsiteOrigin(url:$0).url.absoluteString}
        try expect(originsInPlan.allSatisfy{origin in siteTexts.contains{$0.hasPrefix("Website "+origin+" reference (data only):\n")}} && !original.contains("PRIVATE_UNSELECTED_SITE"),"decoded data preserves both exact plan origins and excludes unrelated site")
        let repeated=try env.store.captureRunReferences(goal:try plan().goal,capabilities:[],websiteURLs:[urls[0],urls[0].appendingPathComponent("other"),urls[1]])
        let siteIDs=repeated.references.included.filter{$0.kind == .website}.map(\.id)
        try expect(siteIDs.count == 2 && Set(siteIDs).count == 2,"same origin paths deduplicate website rows")
        let single=try env.store.captureRunReferences(goal:"",capabilities:[],websiteURL:urls[0])
        let overloaded=try env.store.captureRunReferences(goal:"",capabilities:[],websiteURLs:[urls[0]])
        try expect(single.references == overloaded.references,"single-site API and serialized content remain compatible")
        let unrelated=env.store.websites.lessons.first{$0.text == "PRIVATE_UNSELECTED_SITE"}!
        try expect(env.store.mutateWeb { web,_ in try web.edit(id:unrelated.id,text:"NEXT_UNSELECTED_SITE",evidence:unrelated.evidence) },"ordinary unrelated website edit persisted")
        try capture.check()
        try expect(!capture.revoked && capture.references.message!.content == original,"unrelated edit leaves frozen capture valid")
        let next=try env.store.captureRunReferences(goal:"",capabilities:[],websiteURLs:urls)
        try expect(!next.references.message!.content.contains("NEXT_UNSELECTED_SITE"),"unselected website edit grants no new root")
        let later=try env.store.captureRunReferences(goal:"",capabilities:[],websiteURLs:[unrelated.evidence.sourceURL])
        try expect(later.references.message!.content.contains("NEXT_UNSELECTED_SITE"),"edited data appears only on next capture selecting that site")
        try expect(env.store.mutateWeb { web,_ in
            for host in ["research.example.invalid","comparison.example.invalid","unrelated.example.invalid"] {
                let existing=web.lessons.first{$0.origin.url.host == host}!
                for index in 0..<3 {_ = try web.addManual(text:"Extra website row \(host) \(index)",evidence:existing.evidence)}
            }
        },"persist full website allowance fixtures")
        let all=try env.store.captureRunReferences(goal:"",capabilities:[],websiteURLs:urls+[unrelated.evidence.sourceURL])
        let selected=all.references.included.filter{$0.kind == .website}.map(\.id)
        let origins=Set(env.store.websites.lessons.filter{selected.contains($0.id.uuidString)}.map(\.origin))
        try expect(selected.count == 5 && origins.count == 3,"five global website slots fairly cover three approved origins")
        try expect(all.references.characterCount <= 6000 && all.references.message!.content.utf8.count <= 24000,"website rows share existing combined reference limits")
        do {_ = try env.store.captureRunReferences(goal:"",capabilities:[],websiteURLs:urls+urls);throw Failure(label:"too many website roots accepted")}
        catch let error as RunReferenceError {try expect(error == .invalidEntry,"capture input is bounded to three plan roots")}
    }
    #if DEBUG
    @MainActor private final class MountedSources {
        let browsers:[BrowserSession]
        #if canImport(AppKit)
        let window:NSWindow
        #else
        let window:UIWindow;let previous:UIWindow?
        #endif
        init(_ browsers:[BrowserSession]) throws {
            self.browsers=browsers
            #if canImport(AppKit)
            window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:700),styleMask:[.borderless],backing:.buffered,defer:false)
            let stack=NSStackView(views:browsers.map(\.webView));stack.orientation = .vertical;stack.distribution = .fillEqually
            window.isReleasedWhenClosed=false;window.contentView=stack;window.orderFront(nil)
            #else
            guard let scene=UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).first else {throw Failure(label:"hosted scene unavailable")}
            previous=scene.windows.first(where: \.isKeyWindow);window=UIWindow(windowScene:scene)
            let controller=UIViewController(),stack=UIStackView(arrangedSubviews:browsers.map(\.webView));stack.axis = .vertical;stack.distribution = .fillEqually
            controller.view=stack;window.rootViewController=controller;window.makeKeyAndVisible()
            #endif
        }
        func close(){browsers.forEach{$0.cancel()}
            #if canImport(AppKit)
            window.close()
            #else
            window.isHidden=true;window.rootViewController=nil;previous?.makeKey()
            #endif
        }
    }
    private static func waitForModel(_ model:MultiReferenceModel,session:MultiSourceResearchSession) async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(160))
        while await model.requests.isEmpty,session.running,ContinuousClock.now < end {try await Task.sleep(nanoseconds:20_000_000)}
        let count=await model.requests.count
        try expect(count == 1 && session.receipts.count == 2,"two actual WebKit roots before model")
    }
    private static func waitForFinish(_ session:MultiSourceResearchSession) async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(190))
        while session.running,ContinuousClock.now < end {try await Task.sleep(nanoseconds:10_000_000)}
        try expect(!session.running,"bounded actual Session finish")
    }
    static func actualSourcesAndFrozenEdits() async throws {
        group="actualSourcesAndFrozenEdits";let env=try Environment();defer{env.close()}
        let gate=MultiReferenceGate(),model=MultiReferenceModel(gate:gate,openFirst:true),chat=env.chat(model),session=MultiSourceResearchSession(useLocalFixtures:true)
        let before=try Data(contentsOf:env.vaultURL)
        session.start(plan:try plan(),using:chat)
        let host=try MountedSources(session.browsers);defer{host.close()}
        do {
            try await waitForModel(model,session:session)
            let sent=await model.requests[0]
            try expect(sent[1].role == "user" && sent[1].content.contains("PRIVATE_MULTI_PROFILE") && sent[1].content.contains("PRIVATE_MULTI_MEMORY"),"actual App sends profile/memory in user role")
            try expect(sent[1].content.contains("reference-open") && !sent[1].content.contains("reference-inspect"),"actual model receives only supported reviewed skill")
            try expect(sent[1].content.contains("PRIVATE_MULTI_SITE_ALPHA") && sent[1].content.contains("PRIVATE_MULTI_SITE_BETA") && !sent[1].content.contains("PRIVATE_UNSELECTED_SITE"),"actual model receives only both approved site references")
            try expect(sent[2].content == (try plan()).goal && sent.filter{$0.role == "system"}.count == 1,"current question and fixed authority unchanged")
            try expect(!sent[3].content.contains("PRIVATE_MULTI"),"actual receipt JSON excludes private data")
            try expect(host.browsers.count == 2 && !host.browsers[0].webView.configuration.websiteDataStore.isPersistent && host.browsers[0].webView.configuration.websiteDataStore !== host.browsers[1].webView.configuration.websiteDataStore,"two distinct ephemeral native stores")
            try expect(try Data(contentsOf:env.vaultURL) == before && env.store.memory.memories.allSatisfy{$0.useCount == 0},"actual reads do not write or markUsed")
            try expect(env.store.mutateMemory{_ = try $0.edit(id:$0.memories[0].id,content:"NEXT_RUN_MEMORY")},"edit actual memory while model waiting")
            try expect(env.store.replaceProfileReference(segment:"PRIVATE_MULTI_PROFILE",replacement:"NEXT_RUN_PROFILE"),"edit actual profile while model waiting")
            let website=env.store.websites.lessons.first{$0.text == "PRIVATE_MULTI_SITE_ALPHA"}!
            try expect(env.store.mutateWeb{web,_ in try web.edit(id:website.id,text:"NEXT_RUN_SITE_ALPHA",evidence:website.evidence)},"edit captured website while model waiting")
            let unrelated=env.store.websites.lessons.first{$0.text == "PRIVATE_UNSELECTED_SITE"}!
            try expect(env.store.mutateWeb{web,_ in try web.delete(id:unrelated.id)},"delete unrelated website while model waiting")
            env.store.cancelLearning()
            try expect(session.running,"ordinary edits/unrelated generation preserve actual run")
            let edited=try Data(contentsOf:env.vaultURL)
            await gate.release();try await waitForFinish(session)
            guard let result=session.result else {throw Failure(label:"actual two-source answer missing")}
            let requests=await model.requests
            try expect(requests.count == 2 && requests.allSatisfy{$0[1] == sent[1]},"same frozen references on actual follow-up model call")
            try expect(result.citedSourceCount == 2 && result.receipts.count == 3 && !result.partial,"actual native open supplies third receipt and two-source citations")
            try expect(result.receipts[2].observation.url.path == "/details" && result.findings[0].citations.allSatisfy{$0.receipt.observation.text.contains($0.quote)},"actual navigation and exact observed quotes retained")
            try expect(result.receipts.allSatisfy{!$0.observation.text.contains("PRIVATE_MULTI")},"private references never become ledger evidence")
            let sourceEvidence:[String:Any]=["model_calls":requests.count,"observed_receipts":result.receipts.count,
                "cited_origins":result.citedSourceCount,"ephemeral_webkit_stores":host.browsers.count,
                "last_observed_path":result.receipts.last!.observation.url.path,"reference_role":sent[1].role]
            evidence["actual_sources"]=sourceEvidence
            try expect(try Data(contentsOf:env.vaultURL) == edited,"no learning writes introduced by reference integration")
            let next=try env.store.captureRunReferences(goal:try plan().goal,capabilities:MultiSourceResearchRunner.referenceCapabilities,websiteURLs:try plan().sources.map(\.rootURL))
            try expect(next.references.message!.content.contains("NEXT_RUN_MEMORY") && next.references.message!.content.contains("NEXT_RUN_PROFILE"),"next run receives edited content")
            try expect(next.references.message!.content.contains("NEXT_RUN_SITE_ALPHA") && !next.references.message!.content.contains("PRIVATE_MULTI_SITE_ALPHA"),"next run receives ordinary website edit without changing old receipt evidence")
        } catch {session.cancel();await gate.release();throw error}
    }
    static func actualLateRevocations() async throws {
        group="actualLateRevocations"
        for reason in ["masterOff","clear","profileDelete","profileReplaceDelete","profileToolChainDelete","memoryDelete","websiteDelete","skillDisable","cancel","settings","reload"] {
            let env=try Environment();defer{env.close()}
            let gate=MultiReferenceGate(),returnGate=MultiReferenceGate()
            let model=MultiReferenceModel(gate:gate,returnGate:returnGate,openFirst:true),chat=env.chat(model),session=MultiSourceResearchSession(useLocalFixtures:true)
            session.start(plan:try plan(),using:chat)
            guard let completion=session.capturedRunCompletion else {throw Failure(label:"actual run completion handle missing")}
            let host=try MountedSources(session.browsers);defer{host.close()}
            do {
                try await waitForModel(model,session:session)
                let loads=MultiReferenceLoadCounter()
                let probes=host.browsers.map{$0.webView.observe(\.isLoading,options:[.new]){_,change in if change.newValue == true {loads.record()}}}
                defer{probes.forEach{$0.invalidate()}}
                switch reason {
                case "masterOff":try expect(env.store.updatePreferences{$0.useMemory=false},"persist master off")
                case "clear":try expect(env.store.clearAll(),"actual encrypted clear")
                case "profileDelete":try expect(env.store.deleteProfileReference(segment:"PRIVATE_MULTI_PROFILE"),"captured profile deleted")
                case "profileReplaceDelete":
                    try expect(env.store.replaceProfileReference(segment:"PRIVATE_MULTI_PROFILE",replacement:"NEXT_RUN_PROFILE"),"replace actual captured profile")
                    try expect(env.store.mutateProfile{_ = try $0.add(text:"Unrelated profile B")},"add unrelated profile during run")
                    try expect(env.store.deleteProfileReference(segment:"Unrelated profile B") && session.running,"unrelated deletion leaves actual run alive")
                    try expect(env.store.deleteProfileReference(segment:"NEXT_RUN_PROFILE"),"delete descendant of actual captured profile")
                case "profileToolChainDelete":
                    for (before,after) in [("PRIVATE_MULTI_PROFILE","NEXT_RUN_PROFILE"),("NEXT_RUN_PROFILE","NEXT_RUN_PROFILE")] {
                        try profileTool(env.store,op:"replace",match:before,text:after)
                        try expect(session.running,"tool replacement and no-op preserve actual run")
                    }
                    try profileTool(env.store,op:"delete",match:"NEXT_RUN_PROFILE")
                case "memoryDelete":try expect(env.store.mutateMemory{_ = try $0.delete(id:$0.memories[0].id)},"captured memory deleted")
                case "websiteDelete":try expect(env.store.mutateWeb{web,_ in try web.delete(id:web.lessons.first{$0.text == "PRIVATE_MULTI_SITE_ALPHA"}!.id)},"one captured website deleted")
                case "skillDisable":try expect(env.store.mutateSkills{try $0.suspend(name:"reference-open")},"captured skill suspended")
                case "settings":chat.modelDraft="changed-model";chat.saveSettings()
                case "reload":env.store.reload()
                default:session.cancel()
                }
                try expect(!session.running && session.browsers.isEmpty,"actual Session cancelled and detached all sources")
                await gate.release()
                let end=ContinuousClock.now.advanced(by:.seconds(3))
                while await model.responses == 0,ContinuousClock.now < end {try await Task.sleep(nanoseconds:1_000_000)}
                let produced=await model.responses,notReturned=await model.returnedResponses
                try expect(produced == 1 && notReturned == 0,"provider counter is visible while return gate remains closed")
                // The previous responses/yield observation can pass here even
                // though complete has not returned. Await the captured run,
                // not a provider counter or a guessed number of scheduler turns.
                try expect(session.result == nil && session.receipts.count == 2 && loads.count == 0,"old no-effect observations occur before provider return")
                await returnGate.release()
                await completion.value
                let calls=await model.requests.count,responses=await model.returnedResponses
                try expect(responses == 1 && calls == 1 && session.result == nil && session.receipts.count == 2,"completed late run publishes no result or new receipt")
                try expect(loads.count == 0 && host.browsers.allSatisfy{$0.webView.url?.path == "/start"},"late reply causes zero new native navigation")
                let revocationEvidence:[String:Any]=["model_calls":calls,"late_responses":responses,"new_navigation_starts":loads.count,
                    "retained_receipts":session.receipts.count,"published_result":session.result != nil,
                    "actual_run_completion_awaited":true,"provider_counter_before_return":produced,
                    "provider_returns_at_legacy_observation":notReturned]
                evidence["revocation_"+reason]=revocationEvidence
            } catch {session.cancel();await gate.release();await returnGate.release();await completion.value;throw error}
        }
    }
    private static func profileTool(_ store:LearningStore,op:String,match:String,text:String?=nil) throws {
        let quote=op == "replace" ? "Replace \(match) with \(text!)" : "Delete \(match)"
        var args=["op":op,"match":match,"quote":quote];if let text {args["text"]=text}
        let raw=String(decoding:try JSONSerialization.data(withJSONObject:args),as:UTF8.self)
        let review=try UserProfileToolRequest.parse(raw).prepare(state:store.profile,utterances:[quote])
        _ = try store.commitProfileTool(review,expectedGeneration:store.generation)
    }
    static func actualPrivateCitationRejected() async throws {
        group="actualPrivateCitationRejected";let env=try Environment();defer{env.close()}
        let model=MultiReferenceModel(forged:true),chat=env.chat(model),session=MultiSourceResearchSession(useLocalFixtures:true)
        session.start(plan:try plan(),using:chat);let host=try MountedSources(session.browsers);defer{host.close()}
        try await waitForFinish(session)
        try expect(session.result == nil && session.receipts.count == 2 && session.diagnostic.contains("invalid_citation"),"actual private-reference quotation rejected by unchanged citation ledger")
    }
    #endif
}
#if MULTI_REFERENCE_APP_STANDALONE
@main enum MultiSourceReferenceAppMain {
    @MainActor static func main(){
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await MultiSourceReferenceAppChecks.preflightAndNoNetwork()
                try await MultiSourceReferenceAppChecks.approvedWebsiteCapture()
                #if DEBUG
                try await MultiSourceReferenceAppChecks.actualSourcesAndFrozenEdits()
                try await MultiSourceReferenceAppChecks.actualLateRevocations()
                try await MultiSourceReferenceAppChecks.actualPrivateCitationRejected()
                #endif
                let groups=MultiSourceReferenceAppChecks.counts
                let report:[String:Any]=["passed":groups.values.reduce(0,+),"failed":0,"groups":groups,"evidence":MultiSourceReferenceAppChecks.evidence]
                print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),as:UTF8.self));fflush(stdout);exit(0)
            } catch {
                let failure:[String:Any]=["failed":1,"failure":(error as? MultiSourceReferenceAppChecks.Failure)?.label ?? "operation_failed","groups":MultiSourceReferenceAppChecks.counts]
                print(String(decoding:try! JSONSerialization.data(withJSONObject:failure,options:.sortedKeys),as:UTF8.self));fflush(stdout);exit(1)
            }
        }
        app.run()
    }
}
#else
final class MultiSourceReferenceAppIntegrationTests:XCTestCase {
    @MainActor func testPreflightAndNoNetwork() async throws {try await MultiSourceReferenceAppChecks.preflightAndNoNetwork()}
    @MainActor func testApprovedWebsiteCapture() async throws {try await MultiSourceReferenceAppChecks.approvedWebsiteCapture()}
    #if DEBUG
    @MainActor func testActualSourcesAndFrozenEdits() async throws {try await MultiSourceReferenceAppChecks.actualSourcesAndFrozenEdits()}
    @MainActor func testActualLateRevocations() async throws {try await MultiSourceReferenceAppChecks.actualLateRevocations()}
    @MainActor func testActualPrivateCitationRejected() async throws {try await MultiSourceReferenceAppChecks.actualPrivateCitationRejected()}
    #endif
}
#endif
#endif
