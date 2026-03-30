import XCTest
@testable import ClaudeSquad

final class GitHelperTests: XCTestCase {
    
    var tempDir: String!
    var testRepoPath: String!
    
    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory()
        testRepoPath = (tempDir as NSString).appendingPathComponent("test_repo_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: testRepoPath, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        if let path = testRepoPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        super.tearDown()
    }
    
    // MARK: - GitStatus helper tests
    
    func test_gitStatus_summary_clean() {
        let status = GitStatus(isDirty: false, commitsAhead: 0, commitsBehind: 0, hasRemote: true)
        XCTAssertEqual(status.summary, "up to date")
        XCTAssertFalse(status.hasChanges)
    }
    
    func test_gitStatus_summary_dirtyOnly() {
        let status = GitStatus(isDirty: true, commitsAhead: 0, commitsBehind: 0, hasRemote: true)
        XCTAssertEqual(status.summary, "uncommitted changes")
        XCTAssertTrue(status.hasChanges)
    }
    
    func test_gitStatus_summary_aheadOnly() {
        let status = GitStatus(isDirty: false, commitsAhead: 3, commitsBehind: 0, hasRemote: true)
        XCTAssertEqual(status.summary, "3 unpushed")
        XCTAssertTrue(status.hasChanges)
    }
    
    func test_gitStatus_summary_behindOnly() {
        let status = GitStatus(isDirty: false, commitsAhead: 0, commitsBehind: 2, hasRemote: true)
        XCTAssertEqual(status.summary, "2 to pull")
        XCTAssertTrue(status.hasChanges)
    }
    
    func test_gitStatus_summary_multiple() {
        let status = GitStatus(isDirty: true, commitsAhead: 3, commitsBehind: 1, hasRemote: true)
        XCTAssertEqual(status.summary, "uncommitted changes, 3 unpushed, 1 to pull")
        XCTAssertTrue(status.hasChanges)
    }
    
    func test_gitStatus_summary_noRemote() {
        let status = GitStatus(isDirty: false, commitsAhead: 0, commitsBehind: 0, hasRemote: false)
        XCTAssertEqual(status.summary, "no remote")
        XCTAssertFalse(status.hasChanges)
    }
    
    // MARK: - Branch reading tests
    
    func test_readBranch_returnsNilForNonGitDirectory() {
        let branch = GitHelper.readBranch(projectPath: testRepoPath)
        XCTAssertNil(branch)
    }
    
    func test_readBranch_returnsCurrentBranch() throws {
        // Create a mock .git/HEAD file
        let gitDir = (testRepoPath as NSString).appendingPathComponent(".git")
        try FileManager.default.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        
        let headPath = (gitDir as NSString).appendingPathComponent("HEAD")
        try "ref: refs/heads/main\n".write(toFile: headPath, atomically: true, encoding: .utf8)
        
        let branch = GitHelper.readBranch(projectPath: testRepoPath)
        XCTAssertEqual(branch, "main")
    }
    
    func test_readBranch_handlesFeatureBranch() throws {
        let gitDir = (testRepoPath as NSString).appendingPathComponent(".git")
        try FileManager.default.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        
        let headPath = (gitDir as NSString).appendingPathComponent("HEAD")
        try "ref: refs/heads/feature/my-feature".write(toFile: headPath, atomically: true, encoding: .utf8)
        
        let branch = GitHelper.readBranch(projectPath: testRepoPath)
        XCTAssertEqual(branch, "feature/my-feature")
    }
    
    func test_readBranch_returnsNilForDetachedHead() throws {
        let gitDir = (testRepoPath as NSString).appendingPathComponent(".git")
        try FileManager.default.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        
        let headPath = (gitDir as NSString).appendingPathComponent("HEAD")
        // Detached HEAD state — contains a commit SHA instead of a branch ref
        try "d670460b4b4aece5915caf5c68d12f560a9fe3e4".write(toFile: headPath, atomically: true, encoding: .utf8)
        
        let branch = GitHelper.readBranch(projectPath: testRepoPath)
        XCTAssertNil(branch)
    }
    
    // MARK: - Status reading tests
    
    func test_readStatus_returnsNilForNonGitDirectory() {
        let status = GitHelper.readStatus(projectPath: testRepoPath)
        XCTAssertNil(status)
    }
    
    func test_readStatus_returnsStatusForGitDirectory() throws {
        // Create a mock .git directory
        let gitDir = (testRepoPath as NSString).appendingPathComponent(".git")
        try FileManager.default.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        
        // Note: This test will work with a real git repository.
        // For a mock without running actual git commands, the result depends on
        // whether git commands succeed. In a real test environment, we'd need
        // to actually initialize a git repo.
        
        // Initialize a real git repo for testing
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init"]
        process.currentDirectoryURL = URL(fileURLWithPath: testRepoPath)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        
        let status = GitHelper.readStatus(projectPath: testRepoPath)
        XCTAssertNotNil(status)
        XCTAssertFalse(status!.hasRemote) // New repo has no remote
        XCTAssertEqual(status!.commitsAhead, 0)
        XCTAssertEqual(status!.commitsBehind, 0)
    }
    
    func test_readStatus_detectsDirtyWorkingDirectory() throws {
        // Initialize a real git repo
        let initProcess = Process()
        initProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProcess.arguments = ["init"]
        initProcess.currentDirectoryURL = URL(fileURLWithPath: testRepoPath)
        initProcess.standardOutput = Pipe()
        initProcess.standardError = Pipe()
        try? initProcess.run()
        initProcess.waitUntilExit()
        
        // Add a file
        let testFilePath = (testRepoPath as NSString).appendingPathComponent("test.txt")
        try "test content".write(toFile: testFilePath, atomically: true, encoding: .utf8)
        
        let status = GitHelper.readStatus(projectPath: testRepoPath)
        XCTAssertNotNil(status)
        XCTAssertTrue(status!.isDirty) // Untracked file makes it dirty
    }
    
    func test_readStatus_detectsCleanWorkingDirectory() throws {
        // Initialize a real git repo
        let initProcess = Process()
        initProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProcess.arguments = ["init"]
        initProcess.currentDirectoryURL = URL(fileURLWithPath: testRepoPath)
        initProcess.standardOutput = Pipe()
        initProcess.standardError = Pipe()
        try? initProcess.run()
        initProcess.waitUntilExit()
        
        // Add and commit a file
        let testFilePath = (testRepoPath as NSString).appendingPathComponent("test.txt")
        try "test content".write(toFile: testFilePath, atomically: true, encoding: .utf8)
        
        let addProcess = Process()
        addProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        addProcess.arguments = ["add", "."]
        addProcess.currentDirectoryURL = URL(fileURLWithPath: testRepoPath)
        addProcess.standardOutput = Pipe()
        addProcess.standardError = Pipe()
        try? addProcess.run()
        addProcess.waitUntilExit()
        
        let commitProcess = Process()
        commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        commitProcess.arguments = ["commit", "-m", "Initial commit"]
        commitProcess.currentDirectoryURL = URL(fileURLWithPath: testRepoPath)
        commitProcess.standardOutput = Pipe()
        commitProcess.standardError = Pipe()
        try? commitProcess.run()
        commitProcess.waitUntilExit()
        
        let status = GitHelper.readStatus(projectPath: testRepoPath)
        XCTAssertNotNil(status)
        XCTAssertFalse(status!.isDirty) // Clean working directory after commit
    }
}
