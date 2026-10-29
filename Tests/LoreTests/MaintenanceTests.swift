import Foundation
import Testing

@testable import Lore

/// Tests of repository maintenance on offline repositories.
///
/// The calls that remove anything run only on repositories
/// that the tests create in the scratch directory.
@Suite struct MaintenanceTests {
    /// Creates an offline repository with a committed file and a committed directory.
    private func makeRepository() async throws -> (Repository, Revision) {
        let repository = try await makeOfflineRepository()
        try repository.write("hello\n", to: "a.txt")
        try FileManager.default.createDirectory(atPath: "\(repository.path)/dir", withIntermediateDirectories: true)
        try repository.write("nested\n", to: "dir/b.txt")
        try await repository.stage(["."])
        let revision = try await repository.commit(message: "First")
        return (repository, revision)
    }

    @Test func configurationValues() async throws {
        let repository = try await makeOfflineRepository()
        #expect(try await repository.configurationValue(forKey: .identity) == "test@example.com")
        #expect(try await repository.configurationValue(forKey: .remoteURL) == nil)
        let error = await #expect(throws: LoreError.self) {
            try await repository.configurationValue(forKey: "remote")
        }
        #expect(error?.code == .internal)
    }

    @Test func stateDumpReportsTheTree() async throws {
        let (repository, revision) = try await makeRepository()
        let dump = try await repository.stateDump()
        #expect(dump.repositoryID == (try await repository.state().repositoryID))
        #expect(dump.revision == revision.id)
        #expect(dump.revisionNumber == 1)
        #expect(dump.treeHash.count == 32)
        #expect(dump.nodes.map(\.path) == ["dir/", "dir/b.txt", "a.txt"])
        let file = try #require(dump.nodes.last)
        #expect(file.size == 6)
        let stored = try #require(try await repository.storedContent(of: "a.txt"))
        #expect(file.detail == "addr \(stored.address)")
        let directory = try #require(dump.nodes.first)
        #expect(dump.nodes[1].parentID == directory.id)
        #expect(directory.siblingID == file.id)

        #expect(try await repository.stateDump(maximumDepth: 1).nodes.map(\.path) == ["dir/", "a.txt"])
        #expect(try await repository.stateDump(under: "dir").nodes.map(\.path) == ["dir/", "dir/b.txt"])

        let missingPath = await #expect(throws: LoreError.self) {
            try await repository.stateDump(under: "missing")
        }
        #expect(missingPath?.code == .nodeNotFound)
        let missingRevision = await #expect(throws: LoreError.self) {
            try await repository.stateDump(of: "main@5")
        }
        #expect(missingRevision?.code == .revisionNotFound)
    }

    @Test func stateDumpOfTheStagedState() async throws {
        let (repository, revision) = try await makeRepository()
        try repository.write("changed\n", to: "a.txt")
        try await repository.stage(["a.txt"])

        let staged = try await repository.stateDump()
        #expect(staged.revision != nil)
        #expect(staged.revision != revision.id)
        #expect(staged.revisionNumber == 0)
        #expect(staged.nodes.last?.size == 8)

        let committed = try await repository.stateDump(of: "main@1")
        #expect(committed.revision == revision.id)
        #expect(committed.nodes.last?.size == 6)
    }

    @Test func storeEntriesDescribeTheLocalStore() async throws {
        let (repository, _) = try await makeRepository()
        let stored = try #require(try await repository.storedContent(of: "a.txt"))
        let entries = try await repository.storeEntries(for: stored.address)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.address == stored.address)
        #expect(!entry.isOnServer)
        #expect(entry.match == .address)
        #expect(entry.hasPayload)
        #expect(!entry.isSubfragment)
        #expect(entry.contentSize == stored.size)
        #expect(entry.payloadSize == stored.payloadSize)

        let other = try #require(ContentAddress(hash: stored.address.hash, context: Array(repeating: 7, count: 16)))
        #expect(try await repository.storeEntries(for: other).map(\.match) == [.hashInRepository])
        let unknown = try #require(
            ContentAddress(hash: Array(repeating: 0xab, count: 32), context: stored.address.context)
        )
        let missing = try #require(try await repository.storeEntries(for: unknown).first)
        #expect(missing.match == .notFound)
        #expect(!missing.hasPayload)
        #expect(missing.contentSize == 0)
    }

    @Test func storeEntriesIncludeSubfragments() async throws {
        let repository = try await makeOfflineRepository()
        var generator = SystemRandomNumberGenerator()
        // Random bytes, which the library stores in parts.
        let size = 2 << 20
        let words = (0 ..< size / 8).map { _ in generator.next() }
        try words.withUnsafeBytes { try Data($0).write(to: URL(filePath: "\(repository.path)/large.bin")) }
        try await repository.stage(["large.bin"])
        try await repository.commit(message: "Large")
        let stored = try #require(try await repository.storedContent(of: "large.bin"))

        let top = try await repository.storeEntries(for: stored.address)
        #expect(top.map(\.contentSize) == [size])
        let entries = try await repository.storeEntries(for: stored.address, includingSubfragments: true)
        #expect(entries.first == top.first)
        let parts = entries.dropFirst()
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.isSubfragment && $0.match == .address && $0.hasPayload })
        #expect(parts.allSatisfy { $0.address.context == stored.address.context })
        #expect(parts.map(\.contentSize).reduce(0, +) == size)
    }

    @Test func verifyStateFindsNothingToHeal() async throws {
        let (repository, _) = try await makeRepository()
        #expect(try await repository.verifyState() == false)
        #expect(try await repository.verifyState(of: "dir") == false)
        #expect(try await repository.verifyState(healing: true) == false)
        #expect(try await repository.status().files.isEmpty)
        let error = await #expect(throws: LoreError.self) {
            try await repository.verifyState(of: "missing")
        }
        #expect(error?.code == .nodeNotFound)
    }

    @Test func collectingGarbageKeepsTheContent() async throws {
        let (repository, _) = try await makeRepository()
        let stored = try await repository.storedContent(of: "a.txt")
        try await repository.collectGarbage()
        #expect(try await repository.storedContent(of: "a.txt") == stored)
        #expect(try await repository.verifyState() == false)
    }

    @Test func flushAndReleaseStores() async throws {
        let (repository, _) = try await makeRepository()
        try repository.write("changed\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.flush()
        try await repository.releaseStores()
        // The next operation opens the stores again.
        let status = try await repository.status()
        #expect(status.files.map(\.path) == ["a.txt"])
        #expect(status.files.first?.isStaged == true)
        #expect(try await repository.commit(message: "Change a").number == 2)
    }

    @Test func instancesRecordTheCheckout() async throws {
        let (repository, revision) = try await makeRepository()
        let instances = try await repository.instances()
        #expect(instances.count == 1)
        let instance = try #require(instances.first)
        #expect(instance.path == repository.absolutePath)
        #expect(instance.branch == "main")
        #expect(instance.branchID == revision.branchID)
        #expect(instance.revision == revision.id)
        #expect(instance.staleness == nil)
        #expect(try await repository.pruneStaleInstances().isEmpty)
        #expect(try await repository.instances() == instances)
    }

    @Test func updateInstancePathAfterAMove() async throws {
        // A repository without revisions,
        // because a move right after a commit can lose the commit
        // from the checkout's state (see ``Repository/updateInstancePath()``).
        let repository = try await makeOfflineRepository()
        let original = try #require(try await repository.instances().first)

        let moved = Repository(path: temporaryRepositoryPath("moved"), options: repository.options)
        try FileManager.default.moveItem(atPath: repository.path, toPath: moved.path)
        // The checkout's own registration isn't stale,
        // and it keeps the old path until it's updated.
        #expect(try await moved.instances() == [original])
        #expect(try await moved.pruneStaleInstances().isEmpty)

        try await moved.updateInstancePath()
        var updated = original
        updated.path = moved.absolutePath
        #expect(try await moved.instances() == [updated])
    }

    @Test func serverCallsNeedAServer() async throws {
        let repository = try await makeOfflineRepository()
        let delete = await #expect(throws: LoreError.self) {
            try await repository.deleteFromServer()
        }
        #expect(delete?.code == .noRemote)
        let name = await #expect(throws: LoreError.self) {
            try await Repository.deleteFromServer("test")
        }
        #expect(name?.code == .invalidArguments)
        let list = await #expect(throws: LoreError.self) {
            try await Repository.repositories(on: "")
        }
        #expect(list?.code == .invalidArguments)
    }
}
