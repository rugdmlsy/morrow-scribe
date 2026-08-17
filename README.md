# Morrow Scribe

Slack-native meeting transcription and summarization for macOS.

The first backend reads Slack Huddle live captions through macOS Accessibility instead of recording audio. Slack remains responsible for ASR and speaker attribution; Morrow Scribe persists a structured transcript and can send it to any OpenAI-compatible summarizer.

Slack Desktop 4.51.180 was validated end to end: each live-caption utterance is exposed as three direct Accessibility text nodes — `speaker`, `:`, `caption text`. The collector parses that native structure directly.

## Pipeline

```text
Slack Huddle
  -> Slack live captions / native speaker labels
  -> macOS Accessibility
  -> Morrow Scribe collector
  -> meeting.json + transcript.jsonl + transcript.md + ax-events.jsonl
  -> optional OpenAI-compatible summary
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

`huddle auto-captions-on` enables Slack's persistent “automatically turn on captions” preference. `--learn` records changed Accessibility text nodes and ancestor context to `ax-events.jsonl`. This is intentionally kept in the MVP so Slack UI changes can be diagnosed without audio/OCR.

## Summary provider

Set:

```bash
export MORROW_SCRIBE_LLM_BASE_URL=http://127.0.0.1:11434/v1
export MORROW_SCRIBE_LLM_MODEL=<model>
# optional when the endpoint requires it:
export MORROW_SCRIBE_LLM_API_KEY=<secret>
```

The generated summary uses: TL;DR, Decisions, Action Items, Research Questions, and Open Questions.

## Current scope

- macOS + Slack Desktop
- live-caption AX collector
- direct Slack speaker attribution from the native `speaker : caption` AX structure
- JSONL/Markdown meeting persistence
- raw AX diagnostics
- pluggable summary endpoint

Audio capture / Whisper / pyannote are deliberately not part of the Slack MVP. They remain a fallback for meeting apps that do not expose native captions or speaker identity.
