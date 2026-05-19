# Changelog

## [Unreleased]

### Fixed
- Session status now reflects activity inside running subagents. Previously, sessions invoking a long `Agent`/`Task` call would appear stuck in "Needs Input" because the detector only watched the top-level JSONL, and approval prompts raised by the subagent itself were invisible.

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
