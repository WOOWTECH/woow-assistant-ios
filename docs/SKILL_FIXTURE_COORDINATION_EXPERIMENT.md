# PDF fixture creation and native Files experiment

Status: implemented and locally checked; native A/B results pending. This is a
DEBUG fixture experiment, not an established fix for production user files.

## Evidence and question

`docs/evidence/file-provider-afa1a72.json` records a failing iOS 26 selection with
FileProvider `-1005`, resolver `-1012`, and no SwiftUI importer callback marker.
The exact synthetic source PDF had equal hash, device, inode, size and mtime in
the creation and post-test snapshots. Those snapshots do not establish continuous
presence at the intervening failure instant. A separate SE selection failure had
no corresponding provider error; the two failures must not be conflated.

The fixture currently creates a new file in the shared App Documents directory
using `Data.write(.withoutOverwriting)`. The bounded experiment asks whether
coordinating that one creation changes native selection/callback reliability.
It does not change the importer, `.pdf` filter, URL access, approval steps,
navigation, gesture geometry, timing limits, PDF generator, or export behavior.

Apple documents that [coordinated writing](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate(writingitemat:options:error:byaccessor:))
waits for relevant presenters and supplies the accessor URL to use. The
[open-in-place contract](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html)
requires coordinated access to shared documents. This supports testing the
creation path; neither document identifies these observed provider error codes
as a known iOS bug, nor guarantees provider indexing has completed when a write
returns. The app is not a FileProvider extension and does not signal enumerators.

## Two native arms, one implementation of the assertions

Select each complete test with `-only-testing`:

- A (existing direct creation):
  `WoowAssistantUITests/SkillExecutionUITests/testNativeFilesPDFNeedsBothApprovalsAndReturnsActualText`
- B (coordinated creation):
  `WoowAssistantUITests/SkillExecutionUITests/testCoordinatedFixtureCreationNativePDFNeedsBothApprovalsAndReturnsActualText`

Both call the same full assertion method: real Files picker, exact generated PDF
basename, zero access before approval, separate read and extraction approvals,
two real PDFKit pages and namespace text, and exact dispatch/result counts.
The 240-second case allowance and all picker waits are unchanged. B adds only
`-UITestSkillFixtureWriteMode coordinated` to the existing strict DEBUG fixture
launch. Default/direct remains the existing control. Unknown, missing or duplicate
mode values fail before resolving Documents; Release ignores all fixture flags.

Use the same source, Xcode/runtime/device and preceding test sequence for each
matched pair. Start the paired jobs with equivalent fresh simulator/App data;
do not reuse one arm's Documents/provider state as the other's starting state.
Keep variant results separate (SE iOS 18.5 and current iOS 26.2). Parent controls
CI generation, commit and dispatch; this change adds no workflow or automatic
rerun. A predeclared small matched batch can establish a repeated difference;
one passing B run alone cannot establish causation. If both arms pass, record the
result as inconclusive. If B reproduces the same provider failure, coordination
is insufficient; do not silently change picker copy mode or add fallback retries.

Collect for every case, including failures:

- `SKILL_PDF_FIXTURE_WRITE`: namespace, mode, `willCreate`/`created`/`existing`, UTC epoch.
  A creation experiment needs `created`; `existing` is not a fresh creation trial.
- The unchanged `SKILL_PDF_FIXTURE_BASELINE` schema, callback outcome/count trace,
  and existing post-test `skill-pdf-fixture-evidence.json`.
- Exact picker action/callback/error times, final test result and duration.

The coordinated arm uses the actual accessor URL only if it still identifies the
exact requested synthetic path. Coordination failure, relocation, missing
accessor execution, and a competing creation fail closed; none falls back to a
direct write. The PDF bytes are produced by the same generator before either
write path. No user-selected file is accessed by this experiment.

## Reproducible local acceptance

On macOS with CLT (no package installation, network, simulator or user files):

```sh
swiftc -DDEBUG -parse-as-library Sources/App/SkillExecutionUITestSupport.swift scripts/SkillFixtureCoordinationChecks.swift -o /tmp/woow-skill-fixture-coordination-debug
/tmp/woow-skill-fixture-coordination-debug
swiftc -parse-as-library Sources/App/SkillExecutionUITestSupport.swift scripts/SkillFixtureCoordinationChecks.swift -o /tmp/woow-skill-fixture-coordination-release
/tmp/woow-skill-fixture-coordination-release
python3 scripts/check_skill_fixture_diagnostics.py
```

The new check exercises actual PDFKit data in both arms, idempotent file identity,
strict mode gates, a real directory presenter's change notification, and a real
competing presenter that creates the target before the accessor is granted.
That competing writer's exact bytes must survive and seeding must fail. Release
must resolve no Documents directory for any mode. Run compiled checks with a
bounded subprocess timeout (20 seconds used locally); compilation used 45 seconds.
The existing diagnostic acceptance independently checks byte bounds, links,
metadata refusal, abrupt-exit baseline flush and the unchanged inventory format.

These are macOS Foundation/PDFKit checks. They do not exercise the iOS local
FileProvider service or establish native-picker reliability. No native pass or
production root cause is claimed until the matched CI evidence is available.
