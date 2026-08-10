# claude-squad
A macOS app to help you keep up with multiple Claude sessions.

# Install

```
brew tap armcknight/tools
brew trust armcknight/tools
brew install --cask armcknight/tools/claude-squad
```

Needs macOS 14 Sonoma or newer. Builds are signed with a Developer ID certificate, notarized, and stapled, so no `--no-quarantine` and no Gatekeeper warning.

# Release

Bump the version, then deploy — same targets as the other repos that use the
`armcknight/tools` binaries (needs `vrsn` and `prepare-release` on PATH):

```
make patch      # or minor / major — bumps MARKETING_VERSION and commits
make deploy     # migrates the changelog's Unreleased section, tags, pushes
```

`make deploy` pushing the tag is what starts the release. To do it by hand:

```
git tag 1.0.1 && git push origin 1.0.1
```

`MARKETING_VERSION` in `config/ClaudeSquad.xcconfig` is the source of truth and
must stay valid semver — `vrsn` cannot parse a two-component version like `1.0`.
There is no `deploy-beta`: this app has no `-rc` cask, and the workflow's tag
filter matches only `X.Y.Z`.

`.github/workflows/release.yml` calls the shared `macos-cask-release.yml` workflow in [armcknight/workflows](https://github.com/armcknight/workflows), which archives, signs, notarizes, and staples the app, attaches the zip to a `claude-squad-<version>` release on the [armcknight/homebrew-tools](https://github.com/armcknight/homebrew-tools) tap and to this repo's own release, and bumps `Casks/claude-squad.rb`. The cask points at the tap's copy so it keeps working regardless of this repo's visibility. `MARKETING_VERSION` is stamped from the tag at build time — it is not committed.

# TODO

- [x] Show state of current Claude sessions, sorted by actionability
- [x] Include git branch info for each
- [x] Move to Applications folder — smart prompt with "Don't Ask Again", relaunch after move
- [x] GitHub workflows — CI build/test + release with archiving
- [x] Sentry SDK — crash reporting with swappable ErrorReporter protocol
- [ ] Analytics — `AnalyticsProvider` protocol and event call sites are in place, but no provider is wired up (Amplitude was removed)
- [x] Notifications — alert when a session transitions to "Needs Input"
- [x] Launch at Login toggle in settings
- [ ] Onboarding flow — slides for permissions setup (Full Disk Access if needed, notifications)
- [x] Global hotkey — configurable shortcut to show/focus the window (default ⌘⇧C)
- [x] Changelog — "What's New" menu item + auto-show on version upgrade
- [x] Hardened runtime + notarization — for distribution outside the App Store
- [x] Homebrew cask — `brew install --cask armcknight/tools/claude-squad`
- [x] Automated signing, notarization, and release (shared GitHub Actions workflow rather than fastlane)
- [x] Clean/dirty git index, # unpushed commits, # commits available remotely per session
- [ ] Auto-update mechanism (Sparkle or similar)
- [ ] Keyboard navigation in session list
- [ ] Swift 6 concurrency warnings — `TranscriptLoader.swift:28` mutates a main-actor property from a nonisolated context, and `:71` captures `var self` in concurrently-executing code. Both are warnings today and errors under the Swift 6 language mode, so they block adopting it.
- [x] Inject Git information into Plist and Sentry scope
- [x] Remove the menubar component, make this just window-based
