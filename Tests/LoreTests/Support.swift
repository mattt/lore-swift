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
let isolatedHome: String = {
    let home = scratchDirectory.appending(path: "test-home").path
    try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    setenv("HOME", home, 1)
    return home
}()
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
        options: Repository.Options(identity: "test@example.com", offline: true)
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
