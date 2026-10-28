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

    @Test func repositoryInfo() async throws {
        let (repository, url) = try await makePublishedRepository()
        let info = try await repository.info()
        #expect(info.remote == serverURL)
        #expect(info.name == URL(string: url)?.lastPathComponent)
        #expect(info.defaultBranchName == "main")
        #expect(info.defaultBranchID == (try await repository.status().branchID))
        #expect(info.creator == "alice@example.com")
        #expect(abs(info.creationDate.timeIntervalSinceNow) < 60)
    }

    @Test func repositoryMetadata() async throws {
        let (repository, _) = try await makePublishedRepository()
        try await repository.setRepositoryMetadata(["team": .string("tools"), "size": .number(3)])
        #expect(try await repository.repositoryMetadata(forKey: "team") == .string("tools"))
        #expect(try await repository.repositoryMetadata()["size"] == .number(3))

        try await repository.clearRepositoryMetadata(keys: ["team"])
        let cleared = try await repository.repositoryMetadata()
        #expect(cleared["team"] == nil)
        #expect(cleared["size"] == .number(3))

        try await repository.clearRepositoryMetadata()
        let all = try await repository.repositoryMetadata()
        #expect(all["size"] == nil)
        #expect(all["default-branch-name"] == .string("main"))
    }

    @Test func branchMetadata() async throws {
        let (repository, _) = try await makePublishedRepository()
        try await repository.setBranchMetadata(["owner": .string("alice")])
        try await repository.setBranchMetadata(["reviewed": .boolean(true)], of: "main")
        #expect(try await repository.branchMetadata(forKey: "owner") == .string("alice"))
        #expect(try await repository.branchMetadata(of: "main")["reviewed"] == .boolean(true))

        try await repository.clearBranchMetadata(keys: ["owner"])
        let cleared = try await repository.branchMetadata()
        #expect(cleared["owner"] == nil)
        #expect(cleared["reviewed"] == .boolean(true))

        try await repository.clearBranchMetadata(of: "main")
        let all = try await repository.branchMetadata()
        #expect(all["reviewed"] == nil)
        #expect(all["name"] == .string("main"))
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

    @Test func protectedBranchRefusesPushes() async throws {
        let (repository, _) = try await makePublishedRepository()
        try await repository.protectBranch(named: "main")
        try repository.write("hello again\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "Second")
        let error = await #expect(throws: LoreError.self) {
            try await repository.push()
        }
        #expect(error?.code == .notAuthorized)

        try await repository.unprotectBranch(named: "main")
        #expect(try await repository.push().revisionNumber == 2)
        let info = try await repository.branchInfo()
        #expect(info.remoteLatestRevision == info.latestRevision)
    }

    @Test func archivedBranchesLeaveTheServerListing() async throws {
        let (repository, url) = try await makePublishedRepository()
        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        try repository.write("feature\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "Feature")
        try await repository.push()
        try await repository.switchBranch(to: "main")
        try await repository.archiveBranch(named: "feature")

        let clone = try await Repository.clone(
            from: url,
            to: temporaryRepositoryPath("clone"),
            options: Repository.Options(identity: "bob@example.com")
        )
        #expect(try await clone.branches().map(\.name) == ["main", "main"])
    }

    /// Returns a published repository and a clone of it.
    private func makeClones() async throws -> (alice: Repository, bob: Repository) {
        let (alice, url) = try await makePublishedRepository()
        let bob = try await Repository.clone(
            from: url,
            to: temporaryRepositoryPath("clone"),
            options: Repository.Options(identity: "bob@example.com")
        )
        return (alice, bob)
    }

    @Test(arguments: [MergeSide.merged, .mine, .theirs])
    func syncMergesConflictingCommits(_ side: MergeSide) async throws {
        let (alice, bob) = try await makeClones()
        try alice.write("alice\n", to: "a.txt")
        try await alice.stage(["a.txt"])
        let aliceRevision = try await alice.commit(message: "Alice")
        try await alice.push()
        try bob.write("bob\n", to: "a.txt")
        try await bob.stage(["a.txt"])
        let bobRevision = try await bob.commit(message: "Bob")

        let sync = try await bob.sync()
        #expect(sync.isMerge)
        #expect(sync.hasConflicts)
        #expect(try bob.read("a.txt~mine") == "bob\n")
        #expect(try bob.read("a.txt~theirs") == "alice\n")
        let conflicted = try #require(try await bob.status(ofFile: "a.txt"))
        #expect(conflicted.isMerged && conflicted.isConflicted)

        // In a merge that a sync stages,
        // Lore 0.11.0 resolves with the revision from the server as mine
        // and the local revision as theirs.
        let expected =
            switch side {
            case .merged: "alice and bob\n"
            case .mine: "alice\n"
            case .theirs: "bob\n"
            }
        if side == .merged {
            try bob.write(expected, to: "a.txt")
        }
        #expect(try await bob.resolveConflicts(in: ["a.txt"], keeping: side) == ["a.txt"])
        #expect(try bob.read("a.txt") == expected)
        #expect(try await bob.status(ofFile: "a.txt")?.conflictResolution == side)
        let merge = try await bob.commit(message: "Merge")
        #expect(merge.parents == [aliceRevision.id, bobRevision.id])
        try await bob.push()

        try await alice.sync()
        #expect(try alice.read("a.txt") == expected)
        #expect(try await alice.revision().id == merge.id)
    }

    @Test func mergeABranchFromAnotherClone() async throws {
        let (alice, bob) = try await makeClones()
        try await alice.createBranch(named: "feature")
        try await alice.switchBranch(to: "feature")
        try alice.write("feature\n", to: "a.txt")
        try alice.write("new\n", to: "n.txt")
        try await alice.stage(["."])
        let feature = try await alice.commit(message: "Feature")
        try await alice.push()
        try bob.write("bob\n", to: "a.txt")
        try await bob.stage(["a.txt"])
        let main = try await bob.commit(message: "Bob")
        try await bob.push()

        let result = try await bob.mergeBranch(named: "feature")
        #expect(result.sourceRevision == feature.id)
        #expect(result.conflicts == ["a.txt"])
        #expect(try bob.read("n.txt") == "new\n")
        try await bob.resolveConflicts(in: ["a.txt"], keeping: .theirs)
        let merge = try await bob.commit(message: "Merge feature")
        #expect(merge.parents == [main.id, feature.id])
        #expect(try bob.read("a.txt") == "feature\n")
        #expect(try await bob.push().revision == merge.id)
    }
}
