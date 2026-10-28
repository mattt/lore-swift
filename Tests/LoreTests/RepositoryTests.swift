import Testing

@testable import Lore

/// Tests of local operations on offline repositories,
/// which need the library but no server.
@Suite struct RepositoryTests {
    @Test func createRefusesAnExistingRepository() async throws {
        let repository = try await makeOfflineRepository()
        let error = await #expect(throws: LoreError.self) {
            try await Repository.create(at: repository.path, options: repository.options)
        }
        #expect(error?.code == .repositoryAlreadyExists)
        #expect(error?.code.category == .alreadyExists)
        #expect(error?.message.contains(repository.path) == true)
    }

    @Test func newRepositoryIsOnMainWithoutRevisions() async throws {
        let repository = try await makeOfflineRepository()
        let status = try await repository.status()
        #expect(status.branch == "main")
        #expect(status.branchID != nil)
        #expect(status.revision == nil)
        #expect(status.revisionNumber == 0)
        #expect(status.files.isEmpty)
        #expect(!status.isRemoteAvailable)
    }

    @Test func stageAndCommit() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("hello\n", to: "a.txt")
        try repository.write("world\n", to: "b.txt")

        let untracked = try await repository.status()
        #expect(Set(untracked.files.map(\.path)) == ["a.txt", "b.txt"])
        #expect(untracked.files.allSatisfy { $0.action == .add && $0.isDirty && !$0.isStaged })

        let staged = try await repository.stage(["."])
        #expect(Set(staged.map(\.path)) == ["a.txt", "b.txt"])
        #expect(staged.allSatisfy { $0.action == .add })

        let first = try await repository.commit(message: "Add files")
        #expect(first.number == 1)
        #expect(first.parents.isEmpty)
        #expect(try await repository.status().files.isEmpty)

        try repository.write("hello again\n", to: "a.txt")
        let modified = try #require(try await repository.status().files.first)
        #expect(modified.path == "a.txt")
        #expect(modified.action == .keep)
        #expect(modified.isDirty)

        try await repository.stage(["a.txt"])
        let second = try await repository.commit(message: "Change a")
        #expect(second.number == 2)
        #expect(second.parents == [first.id])
        #expect(second.branchID == first.branchID)

        let status = try await repository.status()
        #expect(status.revision == second.id)
        #expect(status.revisionNumber == 2)
    }

    @Test func commitWithNothingStagedThrows() async throws {
        let repository = try await makeOfflineRepository()
        let error = await #expect(throws: LoreError.self) {
            try await repository.commit(message: "Empty")
        }
        #expect(error?.code == .nothingStaged)
    }

    @Test func syncToEarlierRevision() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("one\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let first = try await repository.commit(message: "One")
        try repository.write("two\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "Two")

        let result = try await repository.sync(to: .id(first.id))
        #expect(result.revision == first.id)
        #expect(result.revisionNumber == 1)
        #expect(!result.isMerge)
        #expect(try repository.read("a.txt") == "one\n")
    }

    @Test func syncToCurrentRevision() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("one\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let revision = try await repository.commit(message: "One")

        for specifier: RevisionSpecifier? in [nil, .latest(), .number(1, on: "main")] {
            let result = try await repository.sync(to: specifier)
            #expect(result.revision == revision.id)
            #expect(result.revisionNumber == 1)
            #expect(!result.isMerge)
        }
    }

    @Test func syncUpdatesEndWithResult() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("one\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "One")
        try repository.write("two\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "Two")

        var updates: [OperationUpdate<SyncProgress, SyncResult>] = []
        for try await update in repository.syncUpdates(to: "main@1") {
            updates.append(update)
        }
        guard case .completed(let result) = updates.last else {
            Issue.record("Expected a result, got \(updates)")
            return
        }
        #expect(result.revisionNumber == 1)
        #expect(try repository.read("a.txt") == "one\n")
    }

    @Test func operationFinishesWhenTaskIsCancelled() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("hello\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let task = Task {
            try await repository.commit(message: "Cancelled")
        }
        task.cancel()
        // The library can't cancel a call,
        // so the commit completes and returns its revision.
        let revision = try await task.value
        #expect(revision.number == 1)
    }

    @Test func lockingNeedsAServer() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("hello\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "First")
        let error = await #expect(throws: LoreError.self) {
            try await repository.lock(["a.txt"])
        }
        #expect(error?.code == .noRemote)
    }

    @Test func repositoryMetadataIncludesTheRepositoryRecord() async throws {
        let repository = try await Repository.create(
            at: temporaryRepositoryPath(),
            name: "described",
            description: "A test repository",
            options: Repository.Options(identity: "test@example.com", isOffline: true)
        )
        let metadata = try await repository.repositoryMetadata()
        #expect(metadata["name"] == .string("described"))
        #expect(metadata["description"] == .string("A test repository"))
        #expect(metadata["default-branch-name"] == .string("main"))
        #expect(metadata["creator"] == .string("test@example.com"))
        #expect(try await repository.repositoryMetadata(forKey: "name") == .string("described"))
        #expect(try await repository.repositoryMetadata(forKey: "missing") == nil)
    }

    @Test func repositoryInfoAndMetadataChangesNeedAServer() async throws {
        let repository = try await makeOfflineRepository()
        let info = await #expect(throws: LoreError.self) {
            try await repository.info()
        }
        #expect(info?.code == .noRemote)
        let set = await #expect(throws: LoreError.self) {
            try await repository.setRepositoryMetadata(["team": .string("tools")])
        }
        #expect(set?.code == .noRemote)
        let clear = await #expect(throws: LoreError.self) {
            try await repository.clearRepositoryMetadata()
        }
        #expect(clear?.code == .noRemote)
    }
}
