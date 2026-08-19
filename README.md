# Morrow Scribe

Slack-native meeting transcription and summarization for macOS.

The first transcription backend reads Slack Huddle live captions through macOS Accessibility instead of recording audio. Slack remains responsible for ASR and speaker attribution; Morrow Scribe persists a structured transcript and can summarize it through the local Codex CLI or an OpenAI-compatible API.

For Slack, the collector prefers the persistent **side-by-side captions** transcript. If that surface is unavailable, it falls back to the transient overlay/hidden captions.

Slack Desktop 4.51.180 was validated end to end: each live-caption utterance is exposed as three direct Accessibility text nodes — `speaker`, `:`, `caption text`. The collector parses that native structure directly.

## Pipeline

```text
Slack Huddle
  -> side-by-side caption transcript (preferred)
     -> overlay/hidden captions (fallback)
  -> Slack native speaker labels
  -> macOS Accessibility
  -> Morrow Scribe collector
  -> meeting.json + transcript.jsonl + transcript.md + ax-events.jsonl
  -> optional Codex CLI / OpenAI-compatible summary
```

The collector briefly foregrounds Slack once at startup to obtain a stable `AXWindow` reference, immediately restores the previously focused app, and then polls that retained window in the background. It does not use OCR or screen capture.

## Commands

```bash
swift run morrow-scribe status
swift run morrow-scribe huddle auto-captions-on
swift run morrow-scribe huddle status
swift run morrow-scribe snapshot --match 字幕
swift run morrow-scribe collect --learn --title "Test Huddle"
swift run morrow-scribe export "~/Library/Application Support/Morrow Scribe/meetings/..."
swift run morrow-scribe summarize "~/Library/Application Support/Morrow Scribe/meetings/..."
```

`huddle auto-captions-on` enables Slack's persistent “automatically turn on captions” preference. `collect` attempts to select Slack's side-by-side caption tab at startup. It retries the semantic Accessibility control, then continues without failing if the control is unavailable; in that case the parser falls back to overlay captions when present. `--learn` records changed Accessibility text nodes and ancestor context to `ax-events.jsonl`. This is intentionally kept in the MVP so Slack UI changes can be diagnosed without audio/OCR.

Transcript JSONL records the actual source per utterance as `slack_ax_side_by_side`, `slack_ax_overlay`, or the generic compatibility fallback.


## Recording sessions and providers

A recording is intentionally longer-lived than any individual meeting-app attachment. Pressing **Start** creates one `MeetingStore` immediately and starts a `RecordingSession`. The session repeatedly probes its configured `RecordingProvider`s, attaches to an active source, appends transcript entries, and returns to monitoring when that source disappears. Only pressing **Stop** ends the store and, when enabled, triggers the final summary.

The default providers are Slack and Zoom. `SlackRecordingProvider` reads Slack Huddle captions; `ZoomRecordingProvider` reads Zoom's native live-caption Accessibility table directly, without RTMS, audio capture, or a second STT engine. Both providers retain their recent caption-buffer state across detach/re-attach, so switching Slack → Zoom → Slack continues writing the same `transcript.jsonl` and final summary. Each transcript row carries a source identifier.

Zoom captions must be enabled in the Zoom meeting UI. On Zoom Workplace 7.1.0 for macOS, the live caption surface is exposed as an `AXTable` named `字幕`/`Captions`; each utterance exposes speaker and caption text as native `AXStaticText` children. Scribe reads that structure passively and does not foreground Zoom or request RTMS access.

## macOS GUI

Morrow Scribe also includes a native SwiftUI app. Build/install the local app bundle with:

```bash
./Scripts/build-app.sh
open "$HOME/Applications/Morrow Scribe.app"
```

The GUI provides:

- Start / stop a persistent recording session; starting does not require a Slack Huddle to already exist
- Continuously monitor Slack, attach when a Huddle begins, detach when it ends, and append later Huddles to the same transcript
- Provider abstraction (`RecordingProvider`) keeps the session/store layer ready for future Zoom or other meeting sources
- Side-by-side captions by default, with overlay caption fallback
- Saved meeting browser backed by `~/Library/Application Support/Morrow Scribe/meetings/`
- Right-click meeting menu for Rename and Delete (with deletion confirmation)
- Transcript and summary content views
- Reveal a meeting directory in Finder
- Manual `Generate Summary` and `Auto summary` controls with either Codex CLI or an OpenAI-compatible API
- In-app summary-provider settings with a lightweight connection test; API keys are stored in macOS Keychain
- `Auto summary` preference persists across app launches
- Structured English summary preview with decisions, action items, next steps, open questions, risks, topic notes, evidence, and confidence
- Copy/export the current concise or detailed summary as Markdown or PDF

Because the GUI is its own macOS application, it needs its own Accessibility permission before it can read Slack captions. Use **Request Access** in the toolbar and enable Morrow Scribe under **System Settings → Privacy & Security → Accessibility**. The app bundle is signed with a stable designated requirement (`identifier "com.morrow.scribe"`) so rebuilding/updating the local app no longer invalidates the Accessibility grant. If upgrading from a build created before this fix, remove the old Accessibility entry and add `~/Applications/Morrow Scribe.app` once to replace the stale CDHash-based grant.

## Summary providers

The macOS app can configure the summary provider directly from **Summary Settings**. Two backends are supported:

- **Codex CLI** — reuses the existing local `codex` login and does not require a separate API key. Scribe auto-detects common install paths such as `~/.local/bin/codex`; an explicit executable path and model override are optional.
- **OpenAI-compatible API** — accepts a base URL, model, and optional API key. API keys are stored in macOS Keychain rather than plaintext preferences.

Codex summaries run through `codex exec` in an empty temporary working directory with `--ephemeral`, a read-only sandbox, approvals disabled, and user config/project rules ignored. This keeps the summary run isolated from unrelated Codex plugins, memory, project instructions, and session history while still reusing the existing Codex authentication.

The CLI keeps the environment-variable path:

Set:

```bash
export MORROW_SCRIBE_LLM_BASE_URL=http://127.0.0.1:11434/v1
export MORROW_SCRIBE_LLM_MODEL=<model>
# optional when the endpoint requires it:
export MORROW_SCRIBE_LLM_API_KEY=<secret>
```

For Codex CLI instead:

```bash
export MORROW_SCRIBE_SUMMARY_PROVIDER=codex
# optional; Scribe auto-detects codex when omitted:
export MORROW_SCRIBE_CODEX_PATH="$HOME/.local/bin/codex"
# optional; otherwise Codex uses its default model:
export MORROW_SCRIBE_CODEX_MODEL=<model>
```

The summarizer first requests grounded structured JSON and persists both `summary.json` and a portable `summary.md`. Summary prose is always generated in English regardless of transcript language, while source evidence retains the original transcript text. The prompt explicitly distinguishes decisions from discussion, requires owners/deadlines to be transcript-supported, prefers empty fields over guesses, and can attach speaker/timestamp/quote evidence plus confidence to important items.

Long transcripts are split into bounded chunks, summarized on one meeting-wide timestamp axis, and then merged through one or more reduction passes. Evidence is checked again in code after every model pass: a quoted citation must match an actual transcript entry, and Morrow Scribe rewrites its speaker/timestamp from the matched entry. Unmatched model citations are removed, their item confidence is lowered, and the summary records a source-quality warning instead of presenting fabricated evidence.

The native preview hides empty sections and surfaces the useful parts first: At a Glance, Decisions, Action Items, Next Steps, Open Questions, Risks / Blockers, plus optional topic-specific notes such as Research Questions or Technical Notes.

## Current scope

- macOS + Slack Desktop
- live-caption AX collector
- direct Slack speaker attribution from the native `speaker : caption` AX structure
- JSONL/Markdown meeting persistence
- raw AX diagnostics
- pluggable summary endpoint

Audio capture / Whisper / pyannote are deliberately not part of the Slack MVP. They remain a fallback for meeting apps that do not expose native captions or speaker identity.
