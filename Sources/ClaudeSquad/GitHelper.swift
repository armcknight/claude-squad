import Foundation

/// Utilities for reading git repository status.
final class GitHelper {
    
    /// Reads the current git branch name from .git/HEAD.
    static func readBranch(projectPath: String, logger: Logger? = nil) -> String? {
        let headPath = (projectPath as NSString).appendingPathComponent(".git/HEAD")
        let content: String
        do {
            content = try String(contentsOfFile: headPath, encoding: .utf8)
        } catch {
            // Not every session runs inside a git repository, so this is expected.
            logger?.debug("GitHelper: cannot read \(headPath): \(error.localizedDescription)")
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: refs/heads/"
        if trimmed.hasPrefix(refPrefix) {
            return String(trimmed.dropFirst(refPrefix.count))
        }
        return nil
    }
    
    /// Reads git status information for a repository.
    /// Returns nil if the directory is not a git repository or git commands fail.
    static func readStatus(projectPath: String, logger: Logger? = nil) -> GitStatus? {
        // Check if .git directory exists
        let gitDir = (projectPath as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else {
            return nil
        }
        
        // Check for uncommitted changes using git status --porcelain
        let isDirty = checkDirtyStatus(projectPath: projectPath)
        
        // Get ahead/behind counts
        let (ahead, behind, hasRemote) = getAheadBehindCounts(projectPath: projectPath, logger: logger)
        
        return GitStatus(
            isDirty: isDirty,
            commitsAhead: ahead,
            commitsBehind: behind,
            hasRemote: hasRemote
        )
    }
    
    // MARK: - Private helpers
    
    /// Checks if the working directory has uncommitted changes.
    private static func checkDirtyStatus(projectPath: String) -> Bool {
        let result = runGitCommand(["status", "--porcelain"], at: projectPath)
        guard let output = result else { return false }
        // If there's any output, the repo is dirty
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    /// Gets the number of commits ahead/behind the remote tracking branch.
    /// Returns (ahead, behind, hasRemote).
    private static func getAheadBehindCounts(projectPath: String, logger: Logger?) -> (Int, Int, Bool) {
        // First check if there's a remote tracking branch
        guard let branch = readBranch(projectPath: projectPath, logger: logger) else {
            return (0, 0, false)
        }
        
        // Get the upstream branch name
        let upstreamResult = runGitCommand(
            ["rev-parse", "--abbrev-ref", "\(branch)@{upstream}"],
            at: projectPath
        )
        
        guard let upstream = upstreamResult?.trimmingCharacters(in: .whitespacesAndNewlines),
              !upstream.isEmpty else {
            // No remote tracking branch configured
            return (0, 0, false)
        }
        
        // Get ahead/behind counts using rev-list
        let aheadResult = runGitCommand(
            ["rev-list", "--count", "\(upstream)..HEAD"],
            at: projectPath
        )
        let behindResult = runGitCommand(
            ["rev-list", "--count", "HEAD..\(upstream)"],
            at: projectPath
        )
        
        let ahead = Int(aheadResult?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
        let behind = Int(behindResult?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
        
        return (ahead, behind, true)
    }
    
    /// Runs a git command in the specified directory and returns its stdout output.
    private static func runGitCommand(_ args: [String], at projectPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // Suppress errors
        
        do {
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else { return nil }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
