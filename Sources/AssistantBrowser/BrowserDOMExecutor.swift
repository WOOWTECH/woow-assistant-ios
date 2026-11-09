#if canImport(WebKit)
import Foundation
import WebKit

/// Fixed isolated-world DOM operations, not an arbitrary JavaScript tool.
/// Synthetic events are not isTrusted. Does not cover frames, closed shadow DOM,
/// file/password inputs, popups, downloads, or browser/CDP network interception.
@MainActor
public final class BrowserDOMExecutor {
    private let webView: WKWebView
    private var continuations: [UUID: CheckedContinuation<String, Error>] = [:]
    public init(webView: WKWebView) { self.webView = webView }

    public func snapshot() async throws -> BrowserDOMSnapshot {
        let value = try await call(mode: "snapshot", arguments: [:])
        guard let data = value.data(using: .utf8), data.count <= 512 * 1024,
              let snapshot = try? JSONDecoder().decode(BrowserDOMSnapshot.self, from: data) else {
            throw BrowserInteractionError.executionFailed
        }
        return snapshot
    }

    /// The native owner must consume the matching gate approval immediately
    /// before this call. Never expose this method as an unapproved model tool.
    /// Success means the DOM operation was dispatched, NOT that a purchase,
    /// submission, navigation or application-level task succeeded.
    public func performApproved(_ proposal: BrowserInteractionProposal) async throws {
        try Task.checkCancellation()
        guard Date() < proposal.expiresAt else { throw BrowserInteractionError.expiredApproval }
        guard webView.url == proposal.pageURL else { throw BrowserInteractionError.staleSnapshot }
        let encoded = try JSONEncoder().encode(proposal.request)
        let payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        let result = try await call(mode: "perform", arguments: payload)
        guard result == "dispatched" else {
            throw BrowserInteractionError(rawValue: result) ?? .executionFailed
        }
    }

    /// Cancels pending native waits, not side effects already dispatched to a
    /// site's listeners. A timed-out/cancelled action must NEVER be retried.
    public func cancel() {
        for id in Array(continuations.keys) { finish(id, .failure(CancellationError())) }
    }

    private func finish(_ id: UUID, _ result: Result<String, Error>) {
        continuations.removeValue(forKey: id)?.resume(with: result)
    }
    private func register(_ id: UUID, _ continuation: CheckedContinuation<String, Error>) {
        continuations[id] = continuation
    }
    private func call(mode: String, arguments: [String: Any]) async throws -> String {
        try Task.checkCancellation()
        let id = UUID()
        let result: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(id, continuation)
                guard !Task.isCancelled else { finish(id, .failure(CancellationError())); return }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                    self?.finish(id, .failure(BrowserInteractionError.timedOut))
                }
                webView.callAsyncJavaScript(Self.script, arguments: [
                    "mode": mode, "request": arguments, "documentNonce": UUID().uuidString,
                    "snapshotNonce": UUID().uuidString, "deadline": Date().addingTimeInterval(10).timeIntervalSince1970 * 1000
                ], in: nil, in: .defaultClient) { [weak self] result in
                    timeout.cancel()
                    switch result {
                    case .success(let value):
                        guard let string = value as? String, string.utf8.count <= 512 * 1024 else {
                            self?.finish(id, .failure(BrowserInteractionError.executionFailed)); return
                        }
                        self?.finish(id, .success(string))
                    case .failure: self?.finish(id, .failure(BrowserInteractionError.executionFailed))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
        try Task.checkCancellation()
        return result
    }

    // All code is app-owned; values enter through WebKit's arguments bridge.
    // Element refs live only in this isolated world, not DOM attributes supplied
    // by the site. Replacing a node (even byte-identical markup) invalidates it.
    private static let script = #"""
    if (Date.now() > deadline) return 'timedOut';
    if (!globalThis.__woowInteraction || globalThis.__woowInteraction.document !== document) {
      globalThis.__woowInteraction = {document, documentID:documentNonce, ids:new WeakMap(), serial:0, records:new Map(), snapshotID:null, url:null};
    }
    const state=globalThis.__woowInteraction;
    const clip=s=>String(s||'').replace(/\s+/g,' ').trim().slice(0,200);
    const visible=e=>{
      if (!e.isConnected || e.closest('[hidden],[inert],[aria-hidden="true"]') || !e.getClientRects().length) return false;
      for (let p=e;p;p=p.parentElement) {const s=getComputedStyle(p);if(s.display==='none'||s.visibility==='hidden'||s.visibility==='collapse'||s.opacity==='0')return false;}
      return true;
    };
    const labelText=e=>Array.from(e.labels||[]).map(l=>{
      const copy=l.cloneNode(true);copy.querySelectorAll('input,select,textarea,button').forEach(n=>n.remove());return copy.textContent;
    }).join(' ');
    const label=e=>clip(e.getAttribute('aria-label') || labelText(e) ||
      e.getAttribute('placeholder') || (e.tagName==='INPUT' ? e.getAttribute('name') : e.textContent) || e.tagName);
    const sensitive=e=>/password|passwd|secret|token|api.?key|credential|one.?time|otp|cc-|credit.?card|card.?number|cvv|cvc|username|login/i.test(
      [e.type,e.name,e.id,e.autocomplete,e.getAttribute('aria-label'),e.getAttribute('placeholder'),labelText(e)].join(' '));
    const describe=e=>{
      if(!visible(e)||sensitive(e)||e.isContentEditable)return null;
      let kind=null,nav=null,method=null;
      const tag=e.tagName,type=(e.type||'').toLowerCase();
      if(tag==='A' && e.hasAttribute('href') && !e.hasAttribute('download')) {kind='link';nav=e.href;method='GET';}
      else if(tag==='BUTTON'||(tag==='INPUT'&&['submit','reset','button'].includes(type)))kind='button';
      else if(tag==='INPUT'&&['checkbox','radio'].includes(type))kind='toggle';
      else if(tag==='TEXTAREA'||(tag==='INPUT'&&['text','search','email','url','tel'].includes(type)))kind='text';
      else if(tag==='SELECT'&&!e.multiple&&e.options.length<=100)kind='select';
      if(!kind)return null;
      if(e.form&&(type==='submit'||(tag==='BUTTON'&&type!=='button'&&type!=='reset'))) {
        nav=e.hasAttribute('formaction')?e.formAction:e.form.action;
        method=(e.hasAttribute('formmethod')?e.formMethod:e.form.method||'GET').toUpperCase();
      }
      // New-window targets are intentionally unavailable, not silently opened
      // in a different tab. Non-HTTP URLs are never exposed as clickable refs.
      const target=e.getAttribute('formtarget')||e.getAttribute('target')||(e.form&&e.form.target)||'';
      if(target&&target!=='_self')return null;
      if(nav) {try {const u=new URL(nav);if(u.protocol!=='https:'||u.username||u.password||nav.length>4096)return null;}catch{return null;}}
      if(method&&!['GET','POST'].includes(method))return null;
      return {kind,label:label(e),enabled:!e.matches(':disabled')&&!e.readOnly&&e.getAttribute('aria-disabled')!=='true',
        options:kind==='select'?Array.from(e.options).map((o,index)=>({index,label:clip(o.label),disabled:o.disabled||(o.parentElement.tagName==='OPTGROUP'&&o.parentElement.disabled)})):[],
        navigationURL:nav,navigationMethod:method};
    };
    const signature=(e,d)=>JSON.stringify([d,e.getAttribute('id'),e.getAttribute('name'),e.getAttribute('type'),e.value,e.checked,
      e.outerHTML.slice(0,20000),e.form?[e.form.action,e.form.method,e.form.target,Array.from(e.form.elements).slice(0,200).map(f=>[f.name,f.type,f.value,f.checked,f.disabled])]:null]);
    if(mode==='snapshot') {
      const controls=[],records=new Map();let scanned=0,truncated=false;
      const nodes=document.querySelectorAll('a[href],button,input,textarea,select');
      for(const e of nodes) {
        if(++scanned>2000||controls.length>=200){truncated=true;break;}
        const d=describe(e);if(!d)continue;
        if(!state.ids.has(e))state.ids.set(e,'e'+(++state.serial));
        const id=state.ids.get(e);controls.push({id,...d});records.set(id,{node:e,signature:signature(e,d)});
      }
      state.records=records;state.snapshotID=snapshotNonce;state.url=location.href;
      return JSON.stringify({documentID:state.documentID,snapshotID:state.snapshotID,url:state.url,controls,truncated});
    }
    if(mode!=='perform')return 'invalidRequest';
    if(state.documentID!==request.documentID||state.snapshotID!==request.snapshotID||state.url!==location.href)return 'staleSnapshot';
    if(request.kind==='scroll') {
      if(!['up','down'].includes(request.direction))return 'invalidRequest';
      state.snapshotID=null;
      window.scrollBy({top:(request.direction==='down'?1:-1)*Math.max(100,Math.min(innerHeight*0.8,1000)),behavior:'instant'});
      return 'dispatched';
    }
    const record=state.records.get(request.controlID);if(!record)return 'unavailableControl';
    const e=record.node,d=describe(e);
    if(!d||!d.enabled||signature(e,d)!==record.signature)return 'staleSnapshot';
    // Scroll into view then recheck actual hit target. Occluded controls are not
    // clicked through; a fresh observation/approval is required after changes.
    e.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'});
    const r=e.getBoundingClientRect(),x=Math.max(0,Math.min(innerWidth-1,r.x+r.width/2)),y=Math.max(0,Math.min(innerHeight-1,r.y+r.height/2));
    const hit=document.elementFromPoint(x,y);
    if(!hit||(hit!==e&&!e.contains(hit)))return 'unavailableControl';
    state.snapshotID=null; // one shot even if the site throws during dispatch
    if(request.kind==='click'&&['button','link','toggle'].includes(d.kind))e.click();
    else if(request.kind==='type'&&d.kind==='text'&&typeof request.text==='string'&&request.text.length<=4096) {
      const prototype=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(prototype,'value').set.call(e,request.text);
      e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));
    } else if(request.kind==='select'&&d.kind==='select'&&Number.isInteger(request.optionIndex)&&d.options.some(o=>o.index===request.optionIndex&&!o.disabled)) {
      e.selectedIndex=request.optionIndex;e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));
    } else return 'invalidRequest';
    return 'dispatched';
    """#
}
#endif
