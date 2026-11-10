# Skills execution increment

This increment provides actual selected-file PDF execution. It does not execute arbitrary Markdown, add Python to iOS, or claim parity with Mika's six original skills. Phone and other native-App automation remain excluded. No remote service, cloud resource or credential is created by this increment. App integration is committed in `a74df45`; simulator validation is recorded in VERIFICATION.md as results arrive.

## Integration contract

The App presents `SkillExecutionView()` from both the Skills page and the `documents` catalog detail inside the existing NavigationStack. This view owns its file importer, options, review, per-step authorization, cancellation and text results. It defaults to native PDFKit. It does not require a model, MCP connection or API key. An optional `SkillExecutionView(worker: configuredWorker)` shows an explicit worker toggle; `configuredWorker` conforms to `SkillExecutionPDFWorker`. Do not label all six skills executable on account of this entry point.

The callable core lives in `Sources/AssistantSkills/SkillExecution*.swift`:

```swift
// Only construct this from the actual document-picker/fileImporter callback.
let selection = try SkillExecutionSelectedFile(userSelectedURL: url)
let options = try SkillExecutionPDFOptions(pages: "1,3-5", metadataOnly: false)
let runtime = try SkillExecutionRuntime(
    selectedFile: selection, options: options,
    catalog: BundledSkillCatalog.bundled())
let plan = runtime.plan
// Display plan.filename, pages, metadataOnly, includesPassword, fingerprint,
// steps' disclosures/availability and provenance before asking for execution.
// For EACH explicit user approval, on that exact runtime:
let approval = try await runtime.authorize(stepID: step.id)
let result = try await runtime.execute(approval)
// .selectedFileRead(byteCount:sha256:) or .pdf(SkillExecutionPDFResult)
// await runtime.nextStep() returns the next reviewable step, or nil.
// await runtime.cancel() invalidates remaining grants and drops the snapshot.
```

`SkillExecutionRuntime` has two separately approved steps: read one selected file into an immutable bounded snapshot; then extract locally OR upload that snapshot to the configured original-script worker. It never silently falls back from native to remote. Each grant is opaque, in-memory, bound to the exact runtime/plan/step, expires after 120 seconds, and is consumed before attempting an effect. Failed attempts require a new grant. Changed inputs require a new runtime. Cancellation discards late results; it cannot recall data already sent to a worker. The host must also cancel its executing `Task` to terminate its network wait; the supplied view does both.

Plans and grants have no public deserialization path. Plan fingerprints cover selection identity, filename, options (password presence only), destination, capability availability, disclosures, step IDs, source paths/revision/hashes. Runtime IDs prevent a grant from one plan being replayed in another. `authorize` is a **trusted UI/orchestrator boundary**, not a model tool. Do not expose it or `SkillExecutionSelectedFile(userSelectedURL:)` to model-supplied URLs or text. Import approval, active/trial status, reference prose and original instructions do not grant execution permission.

`SkillExecutionDependencies.reports(catalog:)` returns all six reviewed dependency reports with source hashes. `hostIntegrationRequired` identifies an existing lower-level path, not a registered or executable runtime operation. Availability for PDF worker execution means an adapter is configured, not that a health probe or deployment has succeeded.

## Pinned original evidence

Repository: <https://github.com/wangzan101/Mika>, revision `0c172724f3f0c96f7345262588072f6e95db1138`, inspected locally at `/tmp/woow-mika-memory-reference`. All six instructions and all three supporting assets were read. Paths below are relative to `core/src/main/resources/skills/`.

| Source | SHA-256 |
| --- | --- |
| `configure-mika/SKILL.md` | `25560ad126c10263f0c341dd5d25d5e12fe4335a372abe7b8d08895725d97c4f` |
| `content-transcribe/SKILL.md` | `fa46715f63de39a274d877f4cc5ec347fb639d7a5bb9aeb8f8b0f81fcf352326` |
| `content-transcribe/references/transcript-output-formats.md` | `bbd7bb15518ecf353d1b26ed8c25a24ee471d0bc7a6dc510b8f8a6153d2dc9e8` |
| `documents/SKILL.md` | `f5cfa97a04bab6fcbfba4b654c9a59018dd339eea83b260ace47928e3abf230c` |
| `documents/scripts/extract_pdf.py` | `41c2e2b51cd23173e0891084d0cd93d54e300e5fd571876740de36ac5968817c` |
| `documents/scripts/manifest.json` | `010bf7bf1102f06e20b29b8b63e0ceedf5b7e6856cb76f67ae8f9e2fa74515cf` |
| `info-research/SKILL.md` | `75f1bd627136a4e022625f7701fef19f07665b0b52718e0f524997cbf61129c2` |
| `messaging/SKILL.md` | `030ef07f6708cea769889a039ee7fcaf8ec3d036032692b83006dc84d99886c9` |
| `skill-authoring/SKILL.md` | `2ca1e847565726ec25b55908e3ecd00d1750664638f8c327d699234ecea37a42` |

The existing catalog verifies its whole resource and individual document hashes. Execution builds provenance from that verified catalog. `scripts/skill-worker/vendor/` contains byte-identical original script/manifest plus upstream LICENSE and NOTICE. Worker startup verifies the script and manifest hashes; it never downloads executable source at runtime.

| Original skill / actual dependency | Existing iOS mapping and this increment's boundary |
| --- | --- |
| configure-mika: `settings_list`, `settings_set` | No equivalent callable settings capability. Model/key/login, data deletion, environment networking/proxy explicitly excluded upstream and here. |
| content-transcribe: `web_read_page`, `read_file` in `/workspace/inbox/`, format reference | `BrowserSession.inspect`, `WebResearchRunner` can provide public-page text. The reference is retained verbatim. Transcript/subtitle-file import, chunked reading and model synthesis are not wired into this runtime. No speech-to-text upstream or here. |
| documents: `web_navigate`, `web_downloads`, `/workspace/inbox`, `/workspace/downloads` | Existing browser navigation/download work is separate. This runtime accepts only a selected PDF, never a workspace path or directory enumeration. A browser-download owner may offer its file through an explicit user selection flow. |
| documents: `run_bundled_script`, `source=skills/documents`, `scripts/extract_pdf.py` | Native PDFKit actual text/selected pages/metadata/unlock path; separately opt-in original Python worker. Native results identify PDFKit and never carry a claim of having run Python. |
| documents: `--out`, `read_file`, `search_files`, `share_file` | Memory result plus explicit native fileExporter of completed UTF-8 text to a user-selected destination; no generic workspace write/share or chunked file-search adapter. |
| documents: `run_command` + pypdf split/merge/extract pages | Arbitrary shell/Python prohibited locally. PDF editing not implemented. OCR absent upstream and here. |
| info-research: `web_navigate` search pages, `web_read_page`, Android app search, independent sources and dates | Existing `WebResearchRunner` + `BrowserSession.inspect/openLink/find` enforce browser policy/same-origin restrictions. No runtime bridge here, no automatic cross-origin policy bypass, no native-App search, no claim of two-source verification unless actually performed. |
| messaging: open account/thread, inspect recipient/body, send and verify | Existing `MCPSession.conversationConnection()` and `MCPConversationRunner` support discovery/selected tools/per-call approval. No messaging tool/account is assumed; this runtime does not register a send capability. Original prose saying not to ask again cannot grant authorization. |
| skill-authoring: `skill_search`, `skill_read`, `ask_user`, `skill_save(markdown, quote, version)` | The manual App flow now uses `SkillAuthoringBridge` for search/read/prepare/review and an atomic encrypted commit through LearningStore. Existing reads, exact request text, current generation, capabilities and full-draft approval are checked before storing a trial skill. No model-callable generic `skill_save` is registered; authoring approval grants no execution permission. Native UI acceptance is tracked in VERIFICATION.md. |

The only original executable asset among the six skills is `extract_pdf.py`. Its manifest is exactly `[{"file":"scripts/extract_pdf.py","runnable":true,"needs":["apk:py3-pypdf"]}]` (whitespace omitted here). It imports Python stdlib `argparse`, `json`, `logging`, `os`, `sys`, and dynamically imports `pypdf.PdfReader` and `pypdf.errors.PdfReadError`. Upstream does **not** pin a Python or pypdf version. The local worker validation environment pins `pypdf==6.21.4`; Python <3.11 additionally needs `typing_extensions==4.16.0`, both wheel hashes locked in requirements. Optional AES crypto and newer PDF filter/font extras are not installed; PDFs requiring them can fail. This is an explicit worker environment choice, not original runtime parity. [pypdf package requirements](https://pypi.org/project/pypdf/6.21.4/)

Original arguments: input path, `--pages` (1-based ranges preserving order/duplicates), `--metadata`, `--out`, `--password`. Original exit 2 means failure; exit 3 means all selected pages have no extractable text. The wrapper accepts only bytes plus pages/metadata/password; it invokes the original in a subprocess, passing a fixed `input.pdf` filename. It runs original metadata first, then each requested page separately, preserving original output while preventing page-marker text inside a PDF from spoofing page boundaries. Empty-page exit 3 becomes an explicit empty-pages result. Original `--out` is not exposed over the protocol; there is no arbitrary filesystem write option.

## Native PDF behavior

The first approved step opens security-scoped access for the selected URL, coordinates access with NSFileCoordinator, rejects directories/symlinks/non-PDF/oversized inputs, bounds the actual read after provider coordination, and balances scope release on success/failure. The snapshot is in memory only; the second step does not reopen a changed file. The supplied selection API is trusted app code; it is not a replacement for Apple's document picker sandbox authorization.

Maximum file size is 10 MiB, maximum selected page count 200, text/metadata output 2 MiB. One-based ranges retain explicit order/duplicates; malformed/empty components and out-of-range pages fail. Metadata-only mode does not read all page text. Password is transient, excluded from plans/hashes, and never logged. Results retain original page numbers, empty-page notices and input SHA-256. Empty text is reported as possibly requiring OCR; it is not asserted to prove an image scan. PDFKit reading-order differences, tables, columns and unsupported/damaged PDFs remain limitations. PDFKit has no hard per-page CPU/memory preemption here: file/page/output limits bound input and returned data, not all parser internal allocation/time. Cancellation is checked between pages and before publishing results.

Apple behavior consulted: [fileImporter security-scoped access](https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:oncompletion:)), [balanced URL access](https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource()), [PDFDocument from Data](https://developer.apple.com/documentation/pdfkit/pdfdocument/init(data:)), [PDFPage text](https://developer.apple.com/documentation/pdfkit/pdfpage/string), [password unlock](https://developer.apple.com/documentation/pdfkit/pdfdocument/unlock(withpassword:)), and [PDF write options for encrypted test fixtures](https://developer.apple.com/documentation/pdfkit/pdfdocumentwriteoption).

## Optional worker protocol and deployment boundary

`worker.py` accepts one JSON object on stdin and emits one JSON response. `--listen-loopback 0` runs the development HTTP harness on an OS-selected port, only at `127.0.0.1`; POST path is `/v1/extract-pdf`. It rejects browser `Origin` requests, unexpected Host names, arbitrary paths/arguments, oversized requests, changed source hashes, invalid input hash and unknown fields. This loopback HTTP server is a test tool, **not** a production internet service.

Request keys are `version:1`, `requestID`, `operation:"extract_pdf"`, pinned `revision`, `scriptSHA256`, `inputSHA256`, `pdfBase64`, `metadataOnly:Bool`, optional `pages`, optional `password`. Response echoes the bounded protocol IDs/hashes and contains `pageCount`, `pages:[{number,text}]`, `metadata:[String:String]`, `emptyPages`, or a fixed `error` category. PDF errors/stderr, passwords and local paths are not returned. Worker source/output hashes are integrity checks for the reviewed protocol, not cryptographic attestation of an untrusted remote operator.

`SkillExecutionHTTPWorker(endpoint:)` accepts HTTPS with no embedded credentials/query/fragment. Its only HTTP exception is explicitly enabled loopback testing. It uses ephemeral URLSession, no shared cookies/cache/credentials, denies redirects, enforces response size and timeout, checks request ID/revision/script/input hashes and exact page sequence. The runtime also validates custom worker results. Host adapters can conform to `SkillExecutionPDFWorker` when an authenticated transport is actually approved; no generic API key setting or placeholder endpoint is supplied.

Local host mode launches a fresh `python -I` process with a private temporary directory, fixed original source, sanitized environment, no shell, CPU/file limits, timeout and cleanup. Linux also applies an address-space limit. **A host subprocess is not an OS filesystem/network sandbox.** The optional Dockerfile supplies a separate deployment recipe; Docker was unavailable on this host and that image was not built/tested. For an isolated per-job stdin worker, an operator can review/build and run:

```sh
docker build -t woow-skill-pdf-worker scripts/skill-worker
docker run --rm -i --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 32 --memory 768m --cpus 1 \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m \
  woow-skill-pdf-worker < request.json
```

This recipe is not executed by iOS and is not an approved/deployed service. Before remote use, missing infrastructure is: an operator-controlled container/job host, a reviewed pinned base image, a TLS/authenticated gateway that forwards only this bounded protocol to per-job isolated stdin workers, request/concurrency limits, secret management, retention/cleanup policy and connectivity/ATS validation. The container should keep egress disabled and mount no user/credential directories. No remote endpoint exists from this work; local HTTP does not prove production isolation, TLS/auth or availability.

## Repeatable validation

On macOS CLT Swift 5.8, use the exact same assertions as the new XCTest file via its standalone mode:

```sh
bash scripts/skill-worker/check_swift.sh
python3 -m venv /tmp/woow-skill-worker-venv
/tmp/woow-skill-worker-venv/bin/python -m pip install --require-hashes -r scripts/skill-worker/requirements.txt
SKILL_EXECUTION_TEST_BINARY="${TMPDIR:-/tmp}/woow-skill-execution-checks" \
  PYTHONDONTWRITEBYTECODE=1 /tmp/woow-skill-worker-venv/bin/python \
  -m unittest discover -s scripts/skill-worker -p 'test_*.py' -v
```

The Swift checker covers real PDFKit text/metadata/page ranges/order/duplicates, empty text, actual encrypted PDF generation/unlock, malformed/oversized files, scope selection boundary, immutable byte snapshots, grant forgery/replay/wrong-plan/expiry, unavailable worker, per-step upload gating and cancellation races. The Python suite exercises actual pinned source in isolated processes, real stdio/HTTP, text/metadata/ranges/empty-page behavior, password handling, schema/source/hash failures, fixed args/paths, and Swift URLSession to real original script. The Swift HTTP test also rejects invalid provenance, wrong page order, redirects and oversized responses. The Python Swift-integration case deliberately skips unless `SKILL_EXECUTION_TEST_BINARY` is set; a skipped run must not be reported as full integration evidence.

Local evidence: Swift core typecheck and standalone PDFKit tests passed; Python tests including actual Swift-to-worker path passed with no skips. `swift build --target AssistantSkills` was attempted and failed before compilation because this CLT installation lacks Xcode SDK `PlatformPath`. Full SwiftPM/XCTest/iOS compilation and file-provider UI behavior require the parent's authorized Xcode CI. SwiftUI file syntax parsing is not an iOS build. The integrated parent workflow now exercises the actual native Files picker; results must be read from that run, not attributed to earlier CI runs.

The completed native result can be exported as bounded UTF-8 plain text through the system destination picker. Its immutable FileDocument is separate from the execution runtime; cancellation keeps the extraction result, and a late callback cannot update a replaced plan. Export serialization is tested with actual file write/readback; native picker save/cancel acceptance is recorded per simulator run.
