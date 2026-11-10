# Approved text and subtitle transcription

The content-transcribe entry now opens a native workflow for a user-selected
UTF-8 `.txt`, `.srt`, `.vtt` or `.md` file. Selection and reading are distinct:
the person must approve the named file before the coordinated read begins.
The read is bounded to 64 KiB and 30 seconds, rejects nonregular/symlink files,
and creates an immutable snapshot. The configured model destination is shown
and must be confirmed before a separate Start action sends any source text.

The browser toolbar offers the same workflow for its current page. An explicit
read extracts a rendered-text snapshot, excluding editable fields and hidden
elements. It does not capture images, media or embedded pages; the UI and model
must not equate reading all snapshot bytes with reading the entire website.
Oversized text is rejected instead of silently truncated to the
research feature's 8,000-character excerpt. The user reviews the captured source
and URL before approving it for the text workflow. This entry does not grant the
model arbitrary URL access or browser navigation.

The actual model receives the fixed Mika content-transcribe SKILL.md and complete
output-format reference at `0c172724`. It calls `read_file` against the approved
memory snapshot, using bounded overlapping UTF-8 ranges. Completion requires
coverage of every byte. Each output section must cite an exact substring of a
range actually read; timestamps must occur in the same quoted text. Quotes are
compared as bytes, not Unicode-normalized approximations. Summary, chapters,
article, transcript and quotations are supported. This verifies source coverage
and citations, not the semantic completeness of every generated summary.

The runtime allows at most 24 model calls and 180 seconds of model time. A malformed command may receive one fixed schema-correction prompt within those same budgets; a second malformed command stops. Invalid ranges, unverified citations and incomplete source coverage stop without correction. Rejected reply text is never replayed or executed. It
supports refusal, cancellation and configuration-change invalidation; delivered
results remain available if settings change. It does not decode audio/video,
create files, write memories or approve skills. Original general-purpose tool
parity remains incomplete.

The privacy manifest declares FileTimestamp reason `3B52.1` for metadata access
to user-granted files, as specified by [Apple's required reason API list](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons).

Local validation: `bash scripts/check_transcript.sh` runs fourteen actual HTTP/core
groups; `bash scripts/check_transcript_ui.sh` checks DEBUG/Release fixture gates
and native-route geometry. The new fixture only creates a namespaced text file;
it does not select/read/approve it or supply a model response. Hosted WebKit
tests cover text beyond the old excerpt, field exclusion, and UTF-8 overflow.

Native acceptance is dispatched through `ios.yml` scope `transcript` and private
`live-model.yml` scopes `transcript-files` / `browser-transcript`. These require
real native file selection or a public WebKit page, actual configured model
requests and verified output. Results must be recorded by source revision;
local checks alone are not native UI, real-model or physical-device acceptance.
