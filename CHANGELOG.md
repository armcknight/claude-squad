# Changelog

## [Unreleased]

### Added
- Subagents now appear as their own indented rows beneath the session that launched them, with their own status icon, type, slug, elapsed time, and full transcript in the detail pane. Selecting a subagent shows its launch prompt (in place of the parent's project/branch, which it shares) and its own conversation. Nested subagents indent further. A parent session's effective sidebar status is rolled up from itself and all descendants using the priority order: needs input > interrupted > idle > running > inactive.
- Transcript now renders the full `AskUserQuestion` content — the question text, each option label and description, and the user's selected answer (plus notes and selected-preview text when present) — instead of a one-line summary.
- Sessions paused on a Claude permission prompt are now detected via `~/.claude/sessions/<pid>.json` and shown as "Needs Input" with a placeholder bubble in the transcript, even when the pending `tool_use` has not been written to the JSONL yet.

### Fixed
- Session status now reflects activity inside running subagents. Previously, sessions invoking a long `Agent`/`Task` call would appear stuck in "Needs Input" because the detector only watched the top-level JSONL, and approval prompts raised by the subagent itself were invisible.
- Open session detail views now refresh their transcript as Claude writes new entries to the JSONL, instead of staying frozen on the snapshot loaded when the view first appeared.

## [1.0.0] - 2026-03-06

### Added
- Main application window showing all active Claude sessions with status, branch, and progress
- Session detail view with project info, status, question text, and action buttons
- Global hotkey (default Cmd+Shift+C) to show/focus the window from anywhere
- Configurable hotkey recorder in Settings
- Launch at Login toggle in Settings
- Settings window with General and About tabs
- Notifications when a session needs input or becomes idle
- Move-to-Applications prompt on first launch
- Sentry crash reporting
- Amplitude analytics
- Git commit and branch info injected into builds
- Arkana-based secret management
