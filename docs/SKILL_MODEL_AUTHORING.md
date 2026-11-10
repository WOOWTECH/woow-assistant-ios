# Model-driven skill authoring

The App's Skills screen and the `skill-authoring` catalog entry now open an actual
model-assisted authoring flow. It uses the configured model through the existing
HTTP client. This is an increment toward the original tool environment, not a
claim that all six bundled skills execute on iOS.

The model can call `skill_read`, `skill_search` and `skill_save`, or ask the user
for clarification. These are strict JSON commands dispatched to the local
`SkillAuthoringBridge`; they are not simulated tool-result text. Each run must
read the pinned original `skill-authoring/SKILL.md` and search existing skills
before preparing a save. Updating an existing skill also requires its full text
and exact current version. Original supporting files are available only through
their catalog paths; reading a script does not execute it.

`skill_save` prepares a review. The UI displays the original request and complete
normalized Markdown. Only the user's approval commits that exact review through
LearningStore's encrypted atomic persistence. A successful commit creates a trial
skill and a receipt; a model's final message cannot produce either. Approval does
not grant browser, MCP, Python or phone-control authority.

Cancellation, changed storage generation or capabilities, and stale read versions
invalidate the operation. There are cumulative limits of twelve model calls,
ten tool calls and 180 seconds of model waiting, plus bounded command/context
sizes. Human review time does not consume the model-wait budget. A rejected tool
argument can be corrected once; transport failures are not automatically retried.
Model configuration and credentials remain private and cannot be changed by these
tools.

## Acceptance

`SkillToolSessionTests` covers actual HTTP request construction and tool-result
feedback, exact reviewed Markdown after encrypted reload, versioned replacement,
refusal, persistence failure, invalid commands, source and quote binding,
clarification with shared budgets, cancellation of a held URLSession request,
timeout, HTTP rejection, and late replies after host changes. Test transports use
synthetic responses; these are not live-model acceptance.

The private `live-model.yml` workflow's `skill-authoring` scope selects
`LiveModelUITests/testRealModelReadsOriginalSkillAndReviewedSaveSurvivesRelaunch`.
It makes real requests through the configured service, requires all three actual
tool operations, inspects the generated review, approves it through the App,
terminates/relaunches, and compares the persisted Markdown byte-for-byte. No draft
or tool reply is preseeded. The existing private-runner cleanup applies, and its
credential-bearing runner configuration and xcresult are not uploaded.

Native UI and live-service results must be recorded by source revision in
VERIFICATION.md. Adding this flow or passing its deterministic tests does not by
itself establish live-model success, full original-runtime parity, or iOS 17
physical-device acceptance.

Actual-model UI follow-up: source `6d480d8`, run [42797710686](https://github.com/WOOWTECH/woow-assistant-ios/actions/runs/42797710686), passed the actual search/read/prepare → UI approval → encrypted exact-document relaunch flow, **1/1, zero skips**, 106.394 seconds on iOS 18.5 iPhone 16 Pro Max. This is separate from complete original-tool or physical-device parity.
