# Native Chat approval notification case plan

Status: dedicated case and observation hook drafted; native compilation and
execution pending. The case has a 300-second execution allowance. Written after the
native App Build step passed in [run 42890969758](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42890969758),
job 130091699137, commit `f28d0bb`. That run later failed its original test-banner
matcher despite the recording showing real OS delivery: the matcher required
App-name text omitted by the compact icon/title/body layout. The initial case's
matcher correction takes priority. App build success does not establish a passing
UI case or approval-sheet re-presentation.

## Ownership and prerequisite

The parent has handed off the existing `NotificationUITests.swift` to repair that
actual native failure, plus the new approval test and the DEBUG fixture-only
observation in `MCPApprovalView.swift`, plus the minimal DEBUG read-only root
route observation in `ContentView.swift`. Other product sources, project
configuration and workflows remain frozen. The dedicated
`Tests/WoowAssistantUITests/NotificationApprovalUITests.swift` contains
`testActualApprovalBannerPreservesProposalUntilExplicitNativeApproval`. Do not add browser DOM
notifications or expand background execution.

The existing fixture is sufficient to propose and execute a real App MCP review:
`-UITestMode -UITestNamespace <new UUID> -UITestResetStorage -UITestMCPFixture`,
then the existing public UI connect/select/send flow with `[fixture:mcp] hello`.
The fixture supplies model/MCP responses; it does not approve the proposal. The
normal ChatSession, approval continuation, notification bridge, UN adapter and
native review buttons remain in use. No external endpoint or personal credential
is needed.

The former observation gap was that `mcp.approval.name` and
`mcp.approval.arguments` exposed the tool and arguments but not
`MCPApprovalRequest.id`. Matching the same text or the same XCUI identifier does
not prove the same pending proposal survived navigation.

The authorized observation interface now implemented is:

- In `MCPApprovalView.swift`, under DEBUG and the existing isolated fixture mode,
  provide a read-only AX value of the actual `proposal.id.uuidString` on the
  existing `mcp.approval.name` Text. Preserve its label `fixture_echo` and existing
  accessibility identifier. Return no such diagnostic outside that fixture mode.
- The value must come from the current proposal, not a test-generated surrogate,
  persisted marker, notification identifier or fixed fixture UUID. It never goes
  into UN content, userInfo, logs of personal runs, or approval actions.
- This hook must not write session state, call resolve, approve, cancel, schedule
  notifications, or modify scene handling. It adds observation only.
- `ContentView.swift` exposes the existing `notificationNavigationID` and selected
  destination as `generation=<UUID>;destination=chat` on
  `notifications.routeObservation`. A DEBUG environment value mirrors this same
  read-only value into `mcp.approval.routeObservation` inside the pending sheet,
  where the root accessibility tree may be hidden. Both require the same strict
  fixture gate. No callback or navigation mutation is added.
- The pending sheet must expose a changed generation with destination `chat`
  before explicit approval. Same proposal UUID and foreground state alone are
  insufficient: both were already true before tapping. The actual notification
  callback remains unchanged, and initialization and that callback are the only
  writers of this generation.

The hook reuses `TaskNotificationStoreConfiguration.resolve(arguments:)`, requires
exactly one local mode and fixture flag, and rejects every Live flag. Its parser
does not create a store, read credentials, or access the notification center.
Missing UUID observation fails the test; text equality cannot replace it.

## Single-case acceptance sequence

1. Launch in a fresh UUID namespace on an owned disposable CI simulator. Before
   connecting MCP or starting any task, open notification settings and assert
   local preference off. Read the actual system authorization. Accept only
   `notDetermined` or `authorized` for this full-banner case; record the branch.
2. Tap `notifications.enable`. Only if authorization was `notDetermined`, accept
   the actual public system notification prompt after verifying its App identity
   and notification purpose. Require final `authorized` and local preference on.
   Never invent a protected-resource raw value, reset authorization privately,
   change host/personal device settings, or have a fixture grant permission.
3. Through the existing native MCP UI, connect the in-process fixture, select
   `fixture_echo`, return to Chat, enable MCP for this conversation, and read the
   root route generation and destination before sending `[fixture:mcp] hello`.
   Keep this same process and MCP connection throughout
   the pending-review, banner tap and explicit approval sequence. Reconnecting
   would reset the fixture call counter and invalidate the evidence.
4. Wait for the actual review controls. Require name `fixture_echo`, parsed
   arguments exactly `{"text":"hello"}`, and both review buttons. Read the AX
   value, parse it as UUID, and retain it as the before-tap proposal ID. There
   must be no assistant result. Retain this review snapshot locally, including
   its modal route generation, which must equal the before-send root generation.
   Do not take a screenshot before tapping the short-lived banner.
5. Require a new actual SpringBoard banner in a bounded visible common subtree
   containing exact title `有操作需要你核准` and exact body
   `請開啟渥屋助理查看並決定；通知不會核准操作。`.
   The compact OS layout may show only an App icon, so do not require separate
   App-name text or invent an icon AX identifier. Establish absence of this
   approval banner before sending. Observe the review
   and banner promptly, without fixed sleeps that let the banner expire. Retain
   the exact observed frame and labels in memory, immediately tap that frame,
   then attach those retained values. Screenshots and additional assertions occur
   only after the tap. The CI recording retains the actual display. A UN scheduling receipt
   or an App-owned text label cannot satisfy this step. Reject fixture tool name,
   arguments and user prompt appearing in the matched banner's text.
6. Tap the observed banner frame while the App remains in the foreground; do not
   open Notification Center, press Home, terminate, or call `app.activate()` to
   manufacture restoration. The normal notification route recreates the root
   NavigationStack while retaining the root ChatSession and notification bridge.
7. Require this App to be `runningForeground` and the native approval sheet to
   be visible and actionable again. Before any explicit approval, require the
   sheet's route observation to contain a changed generation and destination
   `chat`, together with the exact original proposal UUID in the same App
   snapshot. This proves the actual default-open callback occurred and rejects
   both a missed tap and a callback delayed until after approval. Require
   the same synthetic tool/arguments, both review controls, and no assistant
   result. Do not resend the prompt or create a second proposal to make this pass.
8. Tap the native `mcp.approval.approve` exactly once. Require the sheet to close
   and the assistant result to equal `FIXTURE_CALL_1: hello`. On the same fixture
   connection this confirms one tool execution in total. Require the existing
   Chat diagnostics to report attempts=1 and results=1, no error, and no remaining
   approval controls. Check root Chat selection after the modal closes; do not
   require an AX-hidden underlying navigation control while the sheet is present.
   Once the sheet closes, require the root to expose the same changed generation
   already observed inside the pending sheet, with destination `chat`.
   The retained same UUID before the click, followed by this
   single-call result, checks that the notification did not resolve or execute
   the proposal. Never invoke a test-only resolve API.
9. Observe disappearance of the approval banner, then explicitly disable local
   task notifications through settings. This removes this namespace's remaining
   notifications. Do not treat disappearance alone as proof that the OS pending
   and delivered lists are empty; the shared core/App checks cover revocation.
   Do not claim audible sound from settings text or banner evidence.

## Lifecycle boundary and failure evidence

The existing policy cancels pending MCP/profile/memory reviews whenever the scene
is not active. If real OS banner interaction causes that transition and the
pending UUID disappears, record a failing lifecycle observation. Do not suppress
scene cancellation, recreate approval, add background execution, or silently
change the case into a new request. The foreground re-presentation expectation
must be evaluated against actual iOS behavior before any product decision.

The current settings/test-notification case has no pending approval and therefore
does not prove this scenario. A background/relaunch route cannot restore this
ephemeral approval; it may only open Chat. Those are separate cancellation cases.

On failure retain the original UUID if observed, current UUID or absence, actual
banner subtree/frame, App/system screenshots, and existing fixed phase/counter
diagnostics when accessible. Do not infer the proposal UUID from a notification
ID; those UUIDs deliberately differ. Report which stage failed and whether it
was native compilation, permission, real delivery, route/sheet lifetime, UUID
identity, or explicit execution. No synthetic success marker may replace any
of those observations.

The parent owns adding the eventual test class to the intended shard and checking
selected-case counts, zero skips and xcresult terminal success. The `ui-notifications` selector now explicitly includes both `NotificationUITests`
and `NotificationApprovalUITests`. Its expected native count is two methods;
test-target source discovery alone is not accepted as execution.

## Local checks and handoff

Debug and Release iOS syntax parsing passed for the new test and both modified
views. This machine has no iOS SDK: those parses are not typechecking or native
acceptance. Fourteen valid/invalid launch-argument cases passed using the actual
extracted configuration parser and AX gate function compiled with macOS Swift
and warnings-as-errors. They cover production/default, missing or invalid UUID,
duplicate flags, mixed namespaces/modes and Live exclusions. No notification
center was accessed. The final route observation amendment preserves the exact
compiled parser and gate bodies. A source comparison confirms the notification
route handler is unchanged and only initialization and that callback write its
generation. The [local observation-gate record](evidence/task-notifications-approval-local.json)
records source hashes and these limits.

The original settings-case fix and its original-failure evidence are a separate
frozen batch. This case, `ContentView.swift` and `MCPApprovalView.swift` form the
next independently publishable batch. Neither permission/banners nor the exact-UUID native
flow have been validated for this new case yet.
