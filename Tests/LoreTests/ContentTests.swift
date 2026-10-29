import Foundation
import Testing

@testable import Lore

@Suite struct ContentTests {
    /// Returns an offline repository whose revisions 1, 2, and 3 give `a.txt`
    /// the content `one`, `two`, and `three`, and whose first revision adds `b.txt`.
    private func repositoryWithThreeVersions() async throws -> Repository {
        let repository = try await makeOfflineRepository()
        for (index, text) in ["one\n", "two\n", "three\n"].enumerated() {
            try repository.write(text, to: "a.txt")
            if index == 0 {
                try repository.write("bee\n", to: "b.txt")
            }
            try await repository.stage(["."])
            try await repository.commit(message: "Revision \(index + 1)")
        }
        return repository
    }

    /// Returns a new path in the scratch directory, outside every repository.
    private func scratchFile() -> String {
        let directory = scratchDirectory.appending(path: "test-files")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "file-\(UUID().uuidString.prefix(8).lowercased())").path
    }

    @Test func contentHashesMatchTheStoredAddress() async throws {
        let repository = try await repositoryWithThreeVersions()
        let hashes = try await repository.contentHashes(of: ["a.txt", "b.txt"])
        #expect(hashes.map(\.path) == ["a.txt", "b.txt"])
        #expect(hashes.map(\.size) == [6, 4])
        #expect(hashes.allSatisfy { $0.hash.count == 32 })

        let stored = try #require(try await repository.storedContent(of: "a.txt"))
        #expect(stored.address.hash == hashes[0].hash)
        #expect(stored.size == 6)
        #expect(stored.payloadSize > 0)
        #expect(try await repository.storedContent(at: stored.address) == stored)

        try repository.write("changed\n", to: "a.txt")
        let changed = try #require(try await repository.contentHashes(of: ["a.txt"]).first)
        #expect(changed.hash != stored.address.hash)
        #expect(try await repository.storedContent(of: "a.txt") == stored)

        let outside = scratchFile()
        try "three\n".write(toFile: outside, atomically: true, encoding: .utf8)
        #expect(try await repository.contentHashes(of: [outside]).first?.hash == stored.address.hash)

        let error = await #expect(throws: LoreError.self) {
            try await repository.contentHashes(of: ["missing.txt"])
        }
        #expect(error?.code == .invalidArguments)
    }

    @Test func storedContentOfMissingContent() async throws {
        let repository = try await repositoryWithThreeVersions()
        let unknown = try #require(
            ContentAddress(hash: Array(repeating: 0xab, count: 32), context: Array(repeating: 0, count: 16))
        )
        #expect(try await repository.storedContent(at: unknown) == nil)
        let error = await #expect(throws: LoreError.self) {
            try await repository.storedContent(of: "missing.txt")
        }
        #expect(error?.code == .nodeNotFound)
    }

    @Test func writeContentsOfARevision() async throws {
        let repository = try await repositoryWithThreeVersions()
        let destination = scratchFile()
        try await repository.writeContents(of: "a.txt", revision: "main@1", to: destination)
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "one\n")

        let error = await #expect(throws: LoreError.self) {
            try await repository.writeContents(of: "a.txt", to: destination)
        }
        #expect(error?.code == .invalidPath)
        try await repository.writeContents(of: "a.txt", to: destination, replacingExistingFile: true)
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "three\n")

        let stored = try #require(try await repository.storedContent(of: "b.txt"))
        try await repository.writeContents(at: stored.address, to: destination, replacingExistingFile: true)
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "bee\n")

        let missing = await #expect(throws: LoreError.self) {
            try await repository.writeContents(of: "missing.txt", to: scratchFile())
        }
        #expect(missing?.code == .fileNotFound)
        let badRevision = await #expect(throws: LoreError.self) {
            try await repository.writeContents(of: "a.txt", revision: "main@9", to: scratchFile())
        }
        #expect(badRevision?.code == .revisionNotFound)
    }

    @Test func writeContentsInsideTheRepository() async throws {
        let repository = try await repositoryWithThreeVersions()
        try await repository.writeContents(of: "a.txt", revision: "main@2", to: "a-2.txt")
        #expect(try repository.read("a-2.txt") == "two\n")
        let status = try await repository.status()
        #expect(status.files.map(\.path) == ["a-2.txt"])
        #expect(status.files.first?.action == .add)
        #expect(status.files.first?.isStaged == false)
    }

    @Test func obliterateRemovesTheContentOfTheCurrentVersion() async throws {
        let repository = try await repositoryWithThreeVersions()
        let stored = try #require(try await repository.storedContent(of: "a.txt"))

        let result = try await repository.obliterate("a.txt")
        #expect(result.address == stored.address)
        #expect(result.fragmentCount == 1)
        #expect(!FileManager.default.fileExists(atPath: "\(repository.path)/a.txt"))
        let status = try await repository.status()
        #expect(status.files.map(\.path) == ["a.txt"])
        #expect(status.files.first?.action == .delete)
        #expect(status.files.first?.isStaged == true)
        #expect(try await repository.storedContent(at: stored.address) == nil)

        let destination = scratchFile()
        let error = await #expect(throws: LoreError.self) {
            try await repository.writeContents(of: "a.txt", revision: "main@3", to: destination)
        }
        #expect(error?.code == .addressNotFound)
        let audit = await #expect(throws: LoreError.self) {
            try await repository.audit("a.txt", revision: "main@3")
        }
        #expect(audit?.code == .addressNotFound)

        // The earlier versions have other content, which stays.
        try await repository.writeContents(of: "a.txt", revision: "main@2", to: destination)
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "two\n")

        // Lore 0.11.0 can't commit the staged deletion until it's staged again.
        let commit = await #expect(throws: LoreError.self) {
            try await repository.commit(message: "Obliterate a.txt")
        }
        #expect(commit?.code == .internal)
        try await repository.unstage(["a.txt"])
        try await repository.stage(["a.txt"])
        let revision = try await repository.commit(message: "Obliterate a.txt")
        #expect(
            try await repository.changes(in: .id(revision.id)) == [
                FileChange(path: "a.txt", action: .delete, kind: .file)
            ]
        )

        let missing = await #expect(throws: LoreError.self) {
            try await repository.obliterate("missing.txt")
        }
        #expect(missing?.code == .fileNotFound)
    }

    @Test func obliterateContentAtAnAddress() async throws {
        let repository = try await repositoryWithThreeVersions()
        let stored = try #require(try await repository.storedContent(of: "b.txt"))
        let result = try await repository.obliterate(contentAt: stored.address)
        #expect(result.address == stored.address)
        #expect(try await repository.storedContent(at: stored.address) == nil)
        // The working directory and the staged changes don't change.
        #expect(try repository.read("b.txt") == "bee\n")
        #expect(try await repository.status().files.isEmpty)
        let error = await #expect(throws: LoreError.self) {
            try await repository.writeContents(of: "b.txt", to: scratchFile())
        }
        #expect(error?.code == .addressNotFound)
    }

    @Test func contentAddressRoundTripsItsDescription() throws {
        let address = try #require(ContentAddress(hash: Array(0 ..< 32), context: Array(0 ..< 16)))
        #expect(
            address.description
                == "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f-000102030405060708090a0b0c0d0e0f"
        )
        #expect(ContentAddress(address.description) == address)
        #expect(ContentAddress(address.description.uppercased()) == address)
        #expect(ContentAddress(String(address.description.prefix(64))) == nil)
        #expect(ContentAddress("\(address.description)-00") == nil)
        #expect(ContentAddress(hash: [0], context: Array(0 ..< 16)) == nil)
    }
}
