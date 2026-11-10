# Local task notifications

This increment implements default-off local notifications for the actual root
ChatSession: ordinary chat, MCP completion/approval, and profile/memory reviews.
The bridge reads entry count, assistant entry ID/role, submitting state and review
IDs only. It neither reads nor retains message content, review arguments or error
bodies. Independent skill/browser runners are **not wired** by this increment.
There is no push service, phone/App automation or additional background execution.

## Notification approval matrix completed at f49c8f7

The same two native notification cases passed on all three fresh simulators at
`f49c8f7`: SE/iOS 18.5 [42902405880](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42902405880),
Large/iOS 18.5 [42902411329](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42902411329),
and current/iOS 26.2 [42903185255](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42903185255).
Each is **2/2, zero skips**: six executions of two distinct methods. Every device
verified actual OS banner/default-open routing before approval, the same pending
proposal UUID, and one explicit approval followed by exactly one fixture call.
Settings permission, relaunch and disable also passed. [Evidence index and source
boundary](evidence/task-notifications-f49-final-snapshot.json). The later archive
UI changes are outside that tested source snapshot; audible sound, physical
devices and independent browser/skill-runner notifications are not covered.

## App integration

The App delegate installs the UserNotifications delegate before launch completes.
ContentView and the delegate share the same cached TaskNotificationStore. The
root modifier owns the ChatSession observer, and Settings provides the explicit
permission, opt-out, current OS status and test-notification controls.

Opening a notification selects only the chat or browser section and recreates the
root navigation stack identity to dismiss destination-style pushed detail screens.
The root-owned sessions and stores survive that navigation change. No route calls
resolve/approve, replays a tool, or resumes a task. A cold-start stale notification
may open its section; its payload cannot restore an approval or run.

The root modifier retains one bridge for that ChatSession. Initial subscription
values and a run already active when binding are ignored. It forwards @Published
values synchronously, without a scheduler hop or reading old wrapped properties.
The current success contract is a new assistant entry appended during a new
submitting interval. `finish` alone is not success: it also handles cancellation
and errors. The host already rejects late request generations before appending.
An empty/reduced transcript clears notifications, including newConversation,
successful removeSettings and changed model settings. All three review IDs are
watched; nil/resolved removes both pending and delivered approval notifications.

Existing scene cancellation policy stays in place. The modifier additionally
invalidates notification approval records when not active and refreshes system
settings on return. It does not keep a task executing in the background.

Future independent-runner integration can call `service.begin(destination:deadline:)`,
keep the returned opaque ticket, and synchronously forward `.requiresApproval`,
`.approvalResolved`, `.completed`, `.cancelled`, `.expired` or `.failed` to
`receive(_:for:)`. Never infer completion from a generic cleanup method. No such
independent-runner integration is claimed here.

## Consent, copy and bounded state

Only `enableFromUserGesture()` requests `.alert` and `.sound`; its call site is
the explicit settings button. Launch, refresh, task events and factory creation
never request permission. Notification preferences default off even if iOS has
previously granted system permission. App opt-out does not change OS permission.
Denied status exposes the system notification-settings link. Unknown and future
authorization values fail closed. Provisional/ephemeral are displayed honestly;
the explicit test button requires full `authorized` status.

The settings fetch that belongs to an enable click returns its own observed
authorization, even when a concurrent refresh supersedes its UI publication.
An intent token prevents a late grant from undoing disable. Duplicate enable
clicks share the outstanding request. Settings updates use last-started read
ordering so an old callback cannot overwrite newer state.

| Kind | Fixed title | Fixed body |
| --- | --- | --- |
| completed | 任務已完成 | 開啟渥屋助理查看結果。 |
| approval | 有操作需要你核准 | 請開啟渥屋助理查看並決定；通知不會核准操作。 |
| test | 通知測試 | 這是渥屋助理的測試通知。 |

Identifiers contain only a version, storage scope, destination/kind enums and a
new random UUID. The actual UN request has empty userInfo, attachments, category,
thread and subtitle; no badge or custom approval action. Sound is attached only
when the latest system sound setting is enabled. Foreground presentation checks
current consent and that the identifier is still desired before returning
banner/list (and sound when requested). System Focus/summary/silent settings still
control actual presentation and sound. An accepted `add` is not proof of either.

There are at most 32 tracked tasks and one desired notification per task. Oldest
records are evicted; late events cannot recreate missing tickets. Run lifetime is
at most 30 minutes; the chat bridge uses the existing 180-second maximum, while
ChatSession's ordinary-chat 90-second cancellation remains authoritative.
Approval lifetime is at most 180 seconds and cannot outlive the run; a resolved
shorter approval deadline does not shorten the remaining run. Results expire
after 24 hours; test notifications expire after 30 seconds. An active-process
timer, foreground refresh and event processing all check expiry.

OS add/remove calls share one lane. Cancel/disable/resolve updates desired state
synchronously; after every suspended add the lane removes any now-stale request,
including delivered copies. There is no add retry after failure. Error text is
fixed. Re-enabling or re-granting never replays events observed while disabled or
unauthorized. Launch purges this scope's old pending/delivered notifications and
restores only the opt-in bit, not any old task/approval.

iOS does not provide a general delivered-local-notification expiry timer. If the
process is suspended or terminated, wall-clock expiry cleanup runs when execution
resumes/relaunches; an already handed-to-OS notification can briefly race removal.
No stale notification can approve anything. This is not a background-deadline
delivery/removal guarantee. Native CI must exercise actual permission, system
banner, foreground return, relaunch, and tap behavior separately.

## Storage and native accessibility contract

`TaskNotificationStore.applicationStore(arguments:)` caches one instance per
scope for AppDelegate and ContentView. The production suite is
`io.woowtech.assistant.notifications.v1`; the single key is
`task.notifications.enabled.v1`. DEBUG UITest/Live modes require exactly one
valid mode and UUID namespace. Their suite appends `.test.<UUID>` and their OS
identifier prefix contains that UUID. No test namespace falls back to production.

Supported existing launch combinations include UITestMode with LiveMCPUITest,
UITestMCPFixture or UITestTranscript, and LiveModelUITest with
LiveMCPConversationUITest. UITestResetStorage, LiveModelUITestCleanup and
LiveMCPUITestCleanup clear only this feature's preference in that test suite.
Launch cleanup removes only the current scope's notifications; other feature,
production and test-scope identifiers remain untouched. Flags do not activate
test configuration in Release. No fixture implicitly enables notifications.

| Accessibility ID | Stable value/action |
| --- | --- |
| notifications.enabled | actual Text label/value: 已開啟 or 已關閉 |
| notifications.authorization | raw value: unknown, notDetermined, denied, authorized, provisional, ephemeral |
| notifications.sound | raw value: unknown, notSupported, disabled, enabled |
| notifications.alert | same raw setting values |
| notifications.enable | explicit permission/enable Button |
| notifications.disable | app opt-out Button |
| notifications.systemSettings | UIApplication.openNotificationSettingsURLString |
| notifications.refresh | read current settings, no prompt |
| notifications.test | explicit fixed test notification, full authorization only |
| notifications.notice | fixed failure text, only when present |

The status IDs and raw values belong to the actual Text values, not the surrounding
row. `TaskNotificationStore(defaults:center:scope:)` also permits explicit injected
construction; tests must use their own suite and scope, never personal defaults.

## Executable verification and limits

The coherent local snapshot passed **154 core assertions**, **136 Debug App
assertions** and **121 Release App assertions**. Adapter/store configurations also
passed warnings-as-errors typechecking. The actual App compilation retains the
existing BrowserWorkspace async-alternative warning. The earlier run detected
shared source edits and remains recorded as SOURCE_CHANGED in
[the original report](evidence/task-notifications-source-drift.json).
[The final source hashes and checks](evidence/task-notifications-local.json) and
[captured execution log](evidence/task-notifications-local.log) cover one coherent
snapshot; these are not OS notification-delivery results.

Run `python3 scripts/check_task_notifications.py`. It captures actual source bytes
and hashes, compiles real modules and the actual ChatSession/Combine bridge,
executes shared core checks and Debug/Release App checks, and constructs actual
UNNotificationRequest objects without creating/accessing a notification center.
Only model/MCP transports and credential stores are synthetic; the App session,
encrypted temporary learning storage, publications and notification pipeline are
the actual sources. Synthetic private markers are checked for absence from OS
content and metadata. No credentials, personal data or network service is read.

The deterministic enable/refresh two-gate regression failed before the fix with
`overlapping refresh cannot swallow explicit permission request`; the same body
passed after using the click's actual settings result. Separate suspended-add
tests cover disable, cancel, approval resolution and system revocation.

Native Domain tests discover TaskNotificationTests normally. For the hosted
`TaskNotificationAppTests` six-case wrapper, the hosted target includes
`scripts/CheckTaskNotificationApp.swift` and
`Tests/AssistantDomainTests/TaskNotificationChecks.swift`, links AssistantDomain,
AssistantMCP and existing App dependencies, and uses the WoowAssistant host. No
special hosted compilation flag or duplicate core wrapper is required.

The local report distinguishes actual execution from iOS syntax parsing. It does
not establish iOS build, permission prompt, banner/tap, audible sound or physical
device acceptance. NotificationUITests separately requires a real system prompt when undetermined,
a fully authorized status, one bounded SpringBoard banner subtree containing the
exact fixed title/body, absence before the explicit send, and an actual tap that
puts this App in the foreground and reveals root Chat with the pushed notification
settings page gone. App attribution depends on that actual route. iOS 18's compact
banner can show the App icon without a separate App-name text label; the test must
not require an OS-omitted label or accept App-name text embedded in the body as
independent attribution. It also verifies opt-in and opt-out
across relaunch. A screenshot and matched banner labels are attached. Provisional
or denied states are not treated as full banner authorization; external Settings
revocation and audible sound remain separate acceptance. Shared source drift is
reported as SOURCE_CHANGED instead of silently relabeling older results.

The first native settings case at `f28d0bb`, run `42890969758` on fresh iPhone SE
iOS 18.5, built successfully but failed its banner matcher: 1 test, 0 passed,
1 failed, 0 skipped. The public permission prompt and authorized state passed;
the original matcher incorrectly required a separate App-name label. The actual
CI recording shows the fixed notification title/body beside an App icon. This
establishes real visual delivery in the recording, not a passing test or successful
tap/relaunch flow. The [original failure evidence](evidence/task-notifications-native-42890969758.json)
and [unmodified recording frame](evidence/task-notifications-native-42890969758-frame26.png)
are retained. The corrected matcher and foreground-route assertion await another
native run; local syntax parsing does not typecheck or validate XCTest behavior.

## References checked

- Pinned Mika `0c172724f3f0c96f7345262588072f6e95db1138`, locally inspected at
  `/tmp/woow-mika-memory-reference`: `settings/NotificationOverview.kt`,
  `confirm/ConfirmationNotifier.kt`, `task/TaskService.kt` under the Android App.
  Mika separates attention/result/progress and exposes system channel state. Its
  confirmation contents/actions and background service are deliberately not
  ported: this scope requires fixed private-safe copy and navigation only.
- [Apple: requesting permission and reading settings](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications):
  request in context; settings may change; check before scheduling.
- [Apple: notification delegate](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate):
  install before application launch completes; handle presentation and responses.
- [Apple: system notification settings URL](https://developer.apple.com/documentation/uikit/uiapplication/opennotificationsettingsurlstring):
  public app-specific Settings entry point, available since iOS 16.
- [Apple: notification center](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter):
  add, enumerate and remove pending/delivered notifications using public APIs.
