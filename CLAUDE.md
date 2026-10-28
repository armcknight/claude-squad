# Claude Squad

macOS menubar app that monitors Claude Code CLI sessions.

## Build

- Always use XcodeBuildMCP tools to build and test. Fall back to `xcodebuild` CLI only if XcodeBuildMCP is unavailable. Never use `swift build`.
- Run `make xcode` to regenerate the Xcode project any time files are added/removed or target membership changes.
- The project uses XcodeGen (`project.yml`) to generate `ClaudeSquad.xcodeproj`.
- Deployment target: macOS 14.0
- Build phases use CLI tools from the [armcknight/tools](https://github.com/armcknight/tools) Homebrew cask (`inject-git-info`, `upload-symbols`); `make init` installs it via `brew bundle`.

## Swift Best Practices

- **No singletons** (`static let shared`). Use dependency injection from the composition root (`AppDelegate`).
- **No force unwraps** (`!`) in production code. Use `guard let`, `if let`, or optional chaining.
- **No `try?` or `try!`** in production code. Always use `do`/`catch` and handle errors explicitly.
- Private functions and computed properties should go in `private extension` on the type.
- Factor out models and views into their own files.

## Architecture

### Dependency Injection

- Constructor-based DI everywhere. The composition root is `AppDelegate`, which owns all top-level dependencies as strong `let` properties and passes them down.
- Store injected reference-type dependencies as `weak var` in all other types. Guard-let at every access site and log a warning if nil.
- When a class needs a dependency only to pass it further down, still accept it in init and store it.
- Protocols for swappable services: `ErrorReporter`, `AnalyticsProvider`. `ErrorReporter` has a Sentry implementation; `AnalyticsProvider` currently has only the no-op one (Amplitude was removed). Both have no-op implementations for testing.
- When converting a singleton to DI, check all call sites including tests.

### Thread Safety

- Published properties must be updated on the main thread.
- Use `@MainActor` isolation where appropriate.
- Prefer `Task.detached` for background work that must survive SwiftUI view lifecycle.

## Post-Change Checklist

1. **Orphaned code**: Remove dead code paths left behind by changes.
2. **Analytics**: Add events for new user-facing behavior or significant state changes.
3. **Error reporting**: Ensure new error paths report via `ErrorReporter`.
4. **DI wiring**: New dependencies must be threaded from `AppDelegate` through all call sites.
5. **Tests**: Add or update tests for changed behavior.
6. **Thread safety**: Published properties updated on main thread, `@MainActor` isolation respected.

## Project Structure

- `Sources/ClaudeSquad/` — main app source
- `Tests/ClaudeSquadTests/` — unit tests
- `Tests/ClaudeSquadUITests/` — UI tests (screenshots)
- `Fixtures/MockData/` — mock session data for `--mock` mode
- `project.yml` — XcodeGen project definition
- `config/` — xcconfig files
- `docs/` — marketing website and screenshots
- `scripts/` — automation scripts
- `.github/workflows/` — CI/CD
