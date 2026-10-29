import Foundation
import Testing

@testable import Lore

/// Tests of the process-wide settings on ``Library``.
///
/// The library has no way to read these settings back,
/// and most of them take effect only before the first operation of a process,
/// so each test that changes one runs in a child process of its own
/// (an exit test) that starts with the library's defaults.
/// No change reaches the other tests,
/// which run in the parent process at the same time.
/// The suite is serialized so that its child processes run one at a time.
@Suite(.serialized) struct ProcessSettingsTests {
    @Test func threadLimitCanBeSetOnce() async {
        await #expect(processExitsWith: .success) {
            _ = isolatedHome
            #expect(Library.setThreadLimit(8))
            #expect(!Library.setThreadLimit(16))
            #expect(!Library.setThreadLimit(nil))
            let repository = try await makeOfflineRepository()
            #expect(try await repository.status().branch == "main")
        }
    }

    @Test func threadLimitIsRecordedAfterTheFirstOperation() async {
        await #expect(processExitsWith: .success) {
            _ = isolatedHome
            let repository = try await makeOfflineRepository()
            #expect(try await repository.status().branch == "main")
            // Lore 0.11.0 records a limit after its threads have started,
            // despite the header, although the limit can no longer change them.
            #expect(Library.setThreadLimit(8))
            #expect(!Library.setThreadLimit(8))
        }
    }

    @Test func compressionLevelCanBeSetOnce() async {
        await #expect(processExitsWith: .success) {
            _ = isolatedHome
            #expect(Library.setCompressionLevel(1))
            #expect(!Library.setCompressionLevel(nil))
        }
    }

    @Test func compressionLevelIsFixedByTheFirstStoredContent() async {
        await #expect(processExitsWith: .success) {
            _ = isolatedHome
            let repository = try await makeOfflineRepository()
            try repository.write(String(repeating: "lore ", count: 1000), to: "a.txt")
            try await repository.stage(["a.txt"])
            try await repository.commit(message: "First")
            #expect(!Library.setCompressionLevel(22))
        }
    }

    @Test func compressionModeAppliesToContentStoredAfterTheCall() async {
        await #expect(processExitsWith: .success) {
            _ = isolatedHome
            let repository = try await makeOfflineRepository()

            try Library.setCompressionMode(.uncompressed)
            let uncompressed = try await commitText("a.txt", in: repository)
            #expect(uncompressed.payloadSize == uncompressed.size)

            try Library.setCompressionMode(.lz4)
            let lz4 = try await commitText("b.txt", in: repository)
            #expect(lz4.payloadSize < lz4.size / 10)

            try Library.setCompressionMode(.zstandard)
            let zstandard = try await commitText("c.txt", in: repository)
            #expect(zstandard.payloadSize < zstandard.size / 10)

            try Library.setCompressionMode(.automatic)
            let automatic = try await commitText("d.txt", in: repository)
            #expect(automatic.payloadSize < automatic.size / 10)

            // Content stored earlier keeps its encoding.
            #expect(try await repository.storedContent(of: "a.txt") == uncompressed)
        }
    }

    @Test func unsupportedCompressionModesThrow() {
        // A rejected mode changes nothing, so this test runs in the parent process.
        for rawValue: UInt32 in [3, 99] {
            let error = #expect(throws: LoreError.self) {
                try Library.setCompressionMode(Library.CompressionMode(rawValue: rawValue))
            }
            #expect(error?.code == .invalidArguments)
        }
    }
}

/// Commits a file of repetitive text and returns how the store holds it.
private func commitText(_ file: String, in repository: Repository) async throws -> StoredContent {
    try repository.write(String(repeating: "lore \(file) ", count: 500), to: file)
    try await repository.stage([file])
    try await repository.commit(message: "Add \(file)")
    return try #require(try await repository.storedContent(of: file))
}
