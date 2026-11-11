# Completed browser PDF → reviewed document execution

Base: `d9383c73800562dc102007bf36d42d958853e74f`. This is an isolated patch,
not a clean-commit or native-iOS acceptance claim. No deployment endpoint added.

Pinned Mika `0c172724f3f0c96f7345262588072f6e95db1138` documents instructions
accept download inputs (`core/src/main/resources/skills/documents/SKILL.md`,
lines 13–25), and `core/src/main/kotlin/com/wangzan101/mika/core/cap/web/PageReads.kt` exposes
`web_downloads`. The iOS gap was a completed-download screen that could share
a file but could not explicitly hand it to the existing reviewed PDF flow.

## Product path and boundary

`BrowserView` passes a destination builder through `BrowserLibraryView` to
`BrowserDownloadsView`. A completed `.pdf` row has **處理 PDF**. The user opens
that entry, reviews **建立下載 PDF 計畫**, then separately approves the existing
read and extraction steps. Merely downloading, opening the screen, or building
a plan neither reads PDF bytes nor grants execution. Native PDFKit remains the
default; the optional worker still requires its disclosed upload approval.

`BrowserDownloadedPDFSelection(manager:userSelectedID:)` binds the original
completed record, manager-owned URL, volume/inode, length and timestamps. It
checks metadata only. It observes the **published array**, including Combine's
willSet ordering, and invalidates on deletion or record replacement. The actual
App caller rechecks immediately before dispatch and after awaits. A changed
file, revoked selection, cancelled plan or late result cannot refill a new plan.
Manager restoration does not restore selection or approval grants.

The explicit `SkillExecutionSelectedFile(userSelectedBrowserDownloadURL:downloadID:)`
constructor records browser origin in the plan fingerprint; it does not invoke,
impersonate or increment the native picker fixture. Both constructors remain
trusted UI boundaries; neither is a model-callable arbitrary-path capability.

Existing limits remain 10 MiB input, 200 selected pages, 2 MiB text output and
120-second one-use approval grants. Clearing/revoking immediately clears App
state and cancels the task. Synchronous file coordination/PDFKit and an
uncooperative worker are **not forcibly terminated**: held tests release and
join the real old caller, then assert no late publication or extra worker call.
No background execution or notification scope is added. Revocation also
dismisses a download's query sheet and clears its pending export presentation;
the query's existing onDisappear cancellation applies. Already exported copies
or data previously sent under approval cannot be recalled.

## Accurate capability display

Documents `read_file / search_files` is implemented **only** in the independent
DocumentQuery flow over this extraction's bounded text snapshot, after model
destination confirmation and with read-backed exact quotes. The same
`SkillExecutionDependencies.pdfQueryScope` text is shown in the PDF screen at
`skillExecution.pdfQuery.scope`. Generic workspace paths, unlimited reads,
shell/Python and generic skill sharing remain unavailable/excluded or require
host integration. This is not full original-skill parity.

## Parent merge / registration

- New bridge: `Sources/AssistantBrowser/BrowserDownloadedPDFSelection.swift`.
  AssistantBrowser already depends on AssistantSkills; no new module is needed.
- Narrow insertions: BrowserView destination closure, BrowserLibraryView
  forwarding property, BrowserDownloadsView PDF button/destination. Merge the
  last file with Cicero's localization; no localization owner file was edited.
- `SkillExecutionView.swift` takes optional `downloadedPDF:`. Its actual
  `SkillExecutionViewModel` now compiles on macOS outside the SwiftUI guard.
  Keep Raman's current DEBUG picker-identity work when merging; this patch does
  not alter `recordImporterCallback` or add picker observations to downloads.
- Add `scripts/CheckBrowserDownloadedPDFApp.swift` to the existing
  AssistantBrowserIntegrationTests target. Four methods in the new
  `BrowserDownloadedPDFIntegrationTests.swift` reuse these exact bodies.
  Existing target dependencies already include App, Browser and Skills.
- New optional UI inventory/shard registration:
  `SkillPDFCapabilityUITests/testPDFQueryScopeIsAvailableWithoutGrantingWorkspaceAccess`.
  One 120-second label-only case, ordinary isolated UUID namespace, no PDF
  seeder, no permission, no model or worker. Reuses `LearningUITestSupport.swift`.
  It does not claim download/approval UI acceptance.
- Parent owns project/workflow/UI inventory/README/VERIFICATION; none changed.

## Verification

Run `python3 scripts/check_browser_downloaded_pdf_app.py`. Its captured source
snapshot builds Debug and Release with real App caller and modules. It runs a
private loopback server → actual WKDownload → managed file → explicit
selection → first approval/read → second approval/PDFKit. It also covers
same-name independent UUIDs, restored downloads without grants, wrong order,
repeated taps, wrong type, oversize, invalid PDF, 201 selected pages, symlink,
same-size replacement, deletion before/between approvals, held coordinated
read cancellation/new-plan fencing, and late worker revocation.

`scripts/skill-worker/check_swift.sh` retains the original expiry/replay,
coordinated-read, native extraction and upload-gating assertions and adds exact
dependency-scope checks. `scripts/check_document_query_app.py` verifies the
existing query/export caller and compiles its live harness **without running
model requests**. Debug/Release iOS parse checks are syntax only; native hosted
and UI acceptance remain pending parent CI.
