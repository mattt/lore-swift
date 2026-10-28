import Foundation
import Testing

@testable import Lore

/// Tests against a local server.
///
/// Run them with `Scripts/run-integration-tests.sh`,
/// which starts a server and sets `LORE_INTEGRATION=1`.
@Suite(.integration) struct IntegrationTests {
    /// Creates a repository on the server with one pushed revision.
    private func makePublishedRepository(identity: String = "alice@example.com") async throws -> (
        repository: Repository, url: String
    ) {
        let path = temporaryRepositoryPath("published")
        let url = "\(serverURL)/\(URL(filePath: path).lastPathComponent)"
        let repository = try await Repository.create(
            at: path,
            name: url,
            options: Repository.Options(identity: identity)
        )
        try repository.write("hello\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "First")
        try await repository.push()
        return (repository, url)
    }

    @Test func pushReportsProgressAndResult() async throws {
        let path = temporaryRepositoryPath("push")
        let url = "\(serverURL)/\(URL(filePath: path).lastPathComponent)"
        let repository = try await Repository.create(
            at: path,
            name: url,
            options: Repository.Options(identity: "alice@example.com")
        )
        try repository.write("hello\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let revision = try await repository.commit(message: "First")

        let before = try await repository.status()
        #expect(before.isRemoteAvailable)
        #expect(before.isLocalAhead)

        var progress: [PushProgress] = []
        var result: PushResult?
        for try await update in repository.pushUpdates() {
            switch update {
            case .progress(let update): progress.append(update)
            case .completed(let update): result = update
            }
        }
        let push = try #require(result)
        #expect(push.branch == "main")
        #expect(push.remote == serverURL)
        #expect(push.revision == revision.id)
        #expect(push.revisionNumber == 1)
        #expect(push.revisionCount == 1)
        #expect(!push.wasAlreadyPushed)
        #expect(progress.last.map { $0.bytesTransferred == $0.bytesToTransfer } ?? true)

        let after = try await repository.status()
        #expect(after.remoteRevision == revision.id)
        #expect(!after.isLocalAhead)

        let again = try await repository.push()
        #expect(again.wasAlreadyPushed)
    }

    @Test func cloneAndSync() async throws {
        let (repository, url) = try await makePublishedRepository()

        let clonePath = temporaryRepositoryPath("clone")
        var progress: [CloneProgress] = []
        var cloned: Repository?
        for try await update in Repository.cloneUpdates(
            from: url,
            to: clonePath,
            options: Repository.Options(identity: "bob@example.com")
        ) {
            switch update {
            case .progress(let update): progress.append(update)
            case .completed(let repository): cloned = repository
            }
        }
        let clone = try #require(cloned)
        #expect(clone.path == clonePath)
        #expect(try clone.read("a.txt") == "hello\n")
        #expect(progress.last?.filesCloned == 1)
        #expect(progress.last?.isDiscoveryComplete == true)

        try repository.write("hello from alice\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let second = try await repository.commit(message: "Second")
        try await repository.push()

        #expect(try await clone.status().isRemoteAhead)
        let result = try await clone.sync()
        #expect(result.revision == second.id)
        #expect(result.revisionNumber == 2)
        #expect(try clone.read("a.txt") == "hello from alice\n")
    }

    @Test func pushedBranchesAppearOnTheServer() async throws {
        let (repository, url) = try await makePublishedRepository()
        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        try repository.write("feature\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "Feature")
        try await repository.push()

        let clone = try await Repository.clone(
            from: url,
            to: temporaryRepositoryPath("clone"),
            options: Repository.Options(identity: "bob@example.com")
        )
        let remote = try await clone.branches().filter { $0.location == .remote }
        #expect(Set(remote.map(\.name)) == ["main", "feature"])

        try await clone.switchBranch(to: "feature")
        #expect(try clone.read("a.txt") == "feature\n")
    }

    @Test func lockAndUnlock() async throws {
        let (repository, _) = try await makePublishedRepository()

        let lock = try await repository.lock(["a.txt"])
        #expect(lock.acquired == ["a.txt"])
        #expect(lock.alreadyOwned.isEmpty)

        let again = try await repository.lock(["a.txt"])
        #expect(again.acquired.isEmpty)
        #expect(again.alreadyOwned == ["a.txt"])

        let status = try await repository.locks(on: ["a.txt"])
        #expect(status.map(\.path) == ["a.txt"])
        #expect(status.allSatisfy { abs($0.acquisitionDate.timeIntervalSinceNow) < 60 })
        let query = try await repository.locks()
        #expect(query.map(\.path) == ["a.txt"])
        #expect(query.first?.branchID != nil)

        #expect(try await repository.unlock(["a.txt"]) == ["a.txt"])
        #expect(try await repository.unlock(["a.txt"]).isEmpty)
        #expect(try await repository.locks().isEmpty)
    }

    @Test func restoreCommitsAnEarlierRevision() async throws {
        let (repository, _) = try await makePublishedRepository()
        try repository.write("hello again\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let second = try await repository.commit(message: "Second")
        try await repository.push()

        let first = try await repository.revision("main@1")
        try await repository.sync(to: .id(first.id))
        let restored = try await repository.restore(message: "Restore the first revision")
        #expect(restored.number == 3)
        #expect(restored.parents == [second.id])
        #expect(restored.message == "Restore the first revision")
        #expect(restored.metadata["restored-from"] == .hash(first.id.bytes))
        #expect(try repository.read("a.txt") == "hello\n")

        let status = try await repository.status()
        #expect(status.revision == restored.id)
        #expect(status.remoteRevision == restored.id)
    }
}
