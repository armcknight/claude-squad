# Claude Squad

macOS menubar app that monitors Claude Code CLI sessions.

## Build

- Always use `xcodebuild` (via XcodeBuildMCP or CLI) to build, never `swift build`.
- Run `make xcode` to regenerate the Xcode project any time files are added/removed or target membership changes.
- The project uses XcodeGen (`project.yml`) to generate `ClaudeSquad.xcodeproj`.
- Deployment target: macOS 14.0

## Project structure

- `Sources/ClaudeSquad/` — main app source
- `Sources/ClaudeSquadTests/` — tests
- `project.yml` — XcodeGen project definition
