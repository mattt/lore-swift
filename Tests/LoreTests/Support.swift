import Foundation
import Testing

@testable import Lore

/// The scratch directory of the package, which Git ignores.
let scratchDirectory = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: ".scratch")

/// Points `HOME` at a scratch directory,
/// so that the library keeps its per-user data out of the real home directory.
///
/// Every test that calls into the library must evaluate this first,
/// because the library reads `HOME` when it first needs its user directory.
///
/// It also keeps the library's token store in the scratch directory,
/// with its encryption key in a file there instead of the login keychain,
/// and keeps the library's global configuration in the scratch `HOME`.
/// It names a socket for the background service that only the tests use,
/// so that no test reaches a service that the user runs,
/// and removes the variables that would send operations to a service.
let isolatedHome: String = {
    let home = scratchDirectory.appending(path: "test-home").path
    try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    setenv("HOME", home, 1)
    setenv("LORE_AUTH_STORE", "fallback", 1)
    setenv("LORE_AUTH_PATH", "\(home)/auth", 1)
    unsetenv("LORE_GLOBAL_PATH")
    setenv("LORE_SERVICE_SOCKET", "lore_service_swift_tests", 1)
    unsetenv("LORE_USE_SERVICE")
    unsetenv("LORE_SERVICE_EXECUTABLE")
    return home
}()

/// Gives the process its own global Lore configuration and data
/// in a new scratch directory, and returns the directory.
///
/// Call this first in the body of an exit test
/// that changes a setting in the global configuration,
/// so that the change reaches no other test.
/// The library reads `LORE_GLOBAL_PATH` on every call.
func isolateGlobalDirectory() -> String {
    _ = isolatedHome
    let directory =
        scratchDirectory
        .appending(path: "test-global")
        .appending(path: UUID().uuidString.prefix(8).lowercased())
        .path
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    setenv("LORE_GLOBAL_PATH", directory, 1)
    return directory
}

/// Returns a path to an absolute path, relative to the current directory of the process.
func relativePath(to target: String) -> String {
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.pathComponents
    let parts = URL(fileURLWithPath: target).standardizedFileURL.pathComponents
    var common = 0
    while common < min(base.count, parts.count), base[common] == parts[common] {
        common += 1
    }
    return (Array(repeating: "..", count: base.count - common) + parts[common...]).joined(separator: "/")
}

/// Returns a new, unique path in the scratch directory for something other than a repository,
/// such as a shared store.
func temporaryPath(_ label: String) -> String {
    _ = isolatedHome
    let directory = scratchDirectory.appending(path: "test-files")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "\(label)-\(UUID().uuidString.prefix(8).lowercased())").path
}

/// The URL of the local server for integration tests.
let serverURL = ProcessInfo.processInfo.environment["LORE_SERVER_URL"] ?? "lore://127.0.0.1:43537"

extension Trait where Self == ConditionTrait {
    /// Enables a test only when `LORE_INTEGRATION` is `1`,
    /// for tests that need a local server.
    static var integration: Self {
        .enabled(if: ProcessInfo.processInfo.environment["LORE_INTEGRATION"] == "1", "Set LORE_INTEGRATION=1")
    }

    /// Enables a test only when `LORE_AUTHENTICATED_SERVER_URL` is set,
    /// for tests that need a local server that requires tokens.
    static var authenticatedServer: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["LORE_AUTHENTICATED_SERVER_URL"] != nil,
            "Set LORE_AUTHENTICATED_SERVER_URL"
        )
    }
}

/// Returns a new, unique path for a repository in the scratch directory.
func temporaryRepositoryPath(_ label: String = "repository") -> String {
    _ = isolatedHome
    let directory = scratchDirectory.appending(path: "test-repositories")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "\(label)-\(UUID().uuidString.prefix(8).lowercased())").path
}

/// Creates an offline repository in a new scratch directory.
func makeOfflineRepository() async throws -> Repository {
    try await Repository.create(
        at: temporaryRepositoryPath(),
        name: "test",
        options: Repository.Options(identity: "test@example.com", isOffline: true)
    )
}

extension Repository {
    /// Writes text to a file in the repository directory.
    func write(_ text: String, to file: String) throws {
        try text.write(toFile: "\(path)/\(file)", atomically: true, encoding: .utf8)
    }

    /// Reads the text of a file in the repository directory.
    func read(_ file: String) throws -> String {
        try String(contentsOfFile: "\(path)/\(file)", encoding: .utf8)
    }
}
