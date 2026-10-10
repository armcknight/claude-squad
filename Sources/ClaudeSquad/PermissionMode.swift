import Foundation

/// The Claude Code permission mode of a session, read from the `permissionMode`
/// field that Claude Code writes on `permission-mode` and `user` JSONL entries.
enum PermissionMode: String, Equatable {
    case `default`
    case acceptEdits
    case plan
    /// Auto mode: Claude approves tool calls without prompting the user.
    case auto
    /// `--dangerously-skip-permissions`: all permission checks are skipped.
    case bypassPermissions

    /// Whether the session runs tools without asking the user, so the UI
    /// should show a warning.
    var showsWarning: Bool {
        switch self {
        case .auto, .bypassPermissions: return true
        case .default, .acceptEdits, .plan: return false
        }
    }

    /// Tooltip / accessibility text for the warning icon.
    var warningDescription: String {
        switch self {
        case .auto: return "Auto mode is on — Claude runs tools without asking"
        case .bypassPermissions: return "Permissions are bypassed — Claude runs tools without asking"
        case .default, .acceptEdits, .plan: return ""
        }
    }
}
