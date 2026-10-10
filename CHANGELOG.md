# Changelog

## [Unreleased]

### Changed
- Build tooling now comes from the shared [armcknight/tools](https://github.com/armcknight/tools) Homebrew cask, installed by `brew bundle`, in place of a duplicated shell script. `inject-git-info` writes `GIT_COMMIT_HASH`, `GIT_BRANCH` and `GIT_STATUS_CLEAN` into the built Info.plist as a post-build step, and `upload-symbols` uploads dSYMs to Sentry when credentials are available. The About tab and the Sentry scope (`git.clean` tag) now also show if the working tree was clean at build time.

## [1.1.0] 2026-08-08

### Added
- Installable with Homebrew: `brew install --cask armcknight/tools/claude-squad`. Releases are signed with a Developer ID certificate, notarized, and stapled, so the app launches without a Gatekeeper warning.
- Poll interval is now configurable in Settings (General tab), with presets from 1 second to 1 minute. The default remains 3 seconds.
- Task list in the session detail view is now collapsible via a chevron button, keeping the header always visible.
- All sessions in the sidebar now appear inside expandable folder nodes showing their parent directory path, even when the session is the only one in its directory. Previously, solo sessions were shown as flat rows with the full path as their label.
- Subagents now appear as their own indented rows beneath the session that launched them, with their own status icon, type, slug, elapsed time, and full transcript in the detail pane. Selecting a subagent shows its launch prompt (in place of the parent's project/branch, which it shares) and its own conversation. Nested subagents indent further. A parent session's effective sidebar status is rolled up from itself and all descendants using the priority order: needs input > interrupted > idle > running > inactive.

### Fixed
- Open session detail views now refresh their transcript as Claude writes new entries to the JSONL, instead of staying frozen on the snapshot loaded when the view first appeared.
- Sessions paused on a Claude permission prompt are now detected via `~/.claude/sessions/<pid>.json` and shown as "Needs Input" with a placeholder bubble in the transcript, even when the pending `tool_use` has not been written to the JSONL yet.
- Sessions pending `ExitPlanMode` approval now trigger a "Needs Input" notification with the plan text, instead of being shown as idle or interrupted.

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
