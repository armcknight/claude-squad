# claude-squad
A macOS app to help you keep up with multiple Claude sessions.

# TODO

- [x] Show state of current Claude sessions, sorted by actionability
- [x] Include git branch info for each
- [x] Move to Applications folder — smart prompt with "Don't Ask Again", relaunch after move
- [x] GitHub workflows — CI build/test + release with archiving
- [x] Sentry SDK — crash reporting with swappable ErrorReporter protocol
- [x] Analytics (Amplitude) — track feature usage with swappable AnalyticsProvider protocol
- [x] Notifications — alert when a session transitions to "Needs Input"
- [ ] Launch at Login toggle in settings
- [ ] Onboarding flow — slides for permissions setup (Full Disk Access if needed, notifications)
- [ ] Global hotkey — configurable shortcut to show/focus the window
- [ ] Changelog window — show what's new after version upgrades
- [ ] HTTP/log infrastructure improvements — log rotation, compression, size limits
- [ ] Hardened runtime + notarization — for distribution outside the App Store
- [ ] Fastlane — automate signing, notarization, and release
- [ ] Clean/dirty git index, # unpushed commits, # commits available remotely per session
- [ ] Auto-update mechanism (Sparkle or similar)
- [ ] Keyboard navigation in session list
- [x] Inject Git information into Plist and Sentry scope
- [x] Remove the menubar component, make this just window-based
