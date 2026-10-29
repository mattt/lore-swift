import Foundation
import Testing

@testable import Lore

@Suite struct BranchTests {
    @Test func createListAndSwitch() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("hello\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let revision = try await repository.commit(message: "First")

        let main = try #require(try await repository.branches().first)
        #expect(abs(main.creationDate.timeIntervalSinceNow) < 60)
        #expect(main.name == "main")
        #expect(main.isCurrent)
        #expect(main.location == .local)
        #expect(main.latestRevision == revision.id)
        #expect(main.creator == "test@example.com")

        #expect(try await repository.createBranch(named: "feature") == revision.id)
        #expect(try await repository.switchBranch(to: "feature") == revision.id)

        let branches = try await repository.branches()
        #expect(Set(branches.map(\.name)) == ["main", "feature"])
        #expect(branches.first(where: \.isCurrent)?.name == "feature")
        #expect(try await repository.status().branch == "feature")
    }

    @Test func createBranchTwiceThrows() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("hello\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "First")
        try await repository.createBranch(named: "feature")
        let error = await #expect(throws: LoreError.self) {
            try await repository.createBranch(named: "feature")
        }
        #expect(error?.code == .branchAlreadyExists)
    }

    @Test func createBranchNeedsARevision() async throws {
        let repository = try await makeOfflineRepository()
        let error = await #expect(throws: LoreError.self) {
            try await repository.createBranch(named: "feature")
        }
        // Lore 0.12.0 reports this with the internal error code.
        #expect(error?.code == .internal)
    }

    @Test func switchToMissingBranchThrows() async throws {
        let repository = try await makeOfflineRepository()
        let error = await #expect(throws: LoreError.self) {
            try await repository.switchBranch(to: "missing")
        }
        #expect(error?.code == .branchNotFound)
        #expect(error?.trace.isEmpty == false)
    }

    /// Returns an offline repository with two revisions on `main`
    /// and a branch `feature` with one more revision.
    private func repositoryWithFeatureBranch() async throws -> (Repository, main: [Revision], feature: Revision) {
        let repository = try await makeOfflineRepository()
        var main: [Revision] = []
        for message in ["One", "Two"] {
            try repository.write("\(message)\n", to: "a.txt")
            try await repository.stage(["a.txt"])
            main.append(try await repository.commit(message: message))
        }
        try await repository.createBranch(named: "feature", category: "work")
        try await repository.switchBranch(to: "feature")
        try repository.write("feature\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let feature = try await repository.commit(message: "Feature")
        return (repository, main, feature)
    }

    @Test func branchInfoReportsWhereABranchStarted() async throws {
        let (repository, main, feature) = try await repositoryWithFeatureBranch()
        let info = try await repository.branchInfo(named: "feature")
        #expect(info.id == feature.branchID)
        #expect(info.name == "feature")
        #expect(info.category == "work")
        #expect(info.latestRevision == feature.id)
        #expect(info.remoteRevision == nil)
        #expect(info.parentID == main[0].branchID)
        #expect(info.branchPoint == main[1].id)
        #expect(info.creator == "test@example.com")
        #expect(abs(info.creationDate.timeIntervalSinceNow) < 60)
        #expect(!info.isArchived)
        #expect(try await repository.branchInfo() == info)

        let mainInfo = try await repository.branchInfo(named: "main")
        #expect(mainInfo.latestRevision == main[1].id)
        #expect(mainInfo.parentID == nil)
        #expect(mainInfo.branchPoint == nil)

        let error = await #expect(throws: LoreError.self) {
            try await repository.branchInfo(named: "missing")
        }
        #expect(error?.code == .notFound)
    }

    @Test func archiveBranch() async throws {
        let (repository, _, _) = try await repositoryWithFeatureBranch()
        let current = await #expect(throws: LoreError.self) {
            try await repository.archiveBranch(named: "feature")
        }
        #expect(current?.code == .branchNotFound)

        try await repository.switchBranch(to: "main")
        try await repository.archiveBranch(named: "feature")
        #expect(try await repository.branches().map(\.name) == ["main"])
        let archived = try await repository.branches(includingArchived: true).filter(\.isArchived)
        #expect(archived.map(\.name) == ["feature"])
    }

    @Test func protectAndUnprotectBranch() async throws {
        let (repository, _, _) = try await repositoryWithFeatureBranch()
        #expect(try await repository.branchMetadata(forKey: "protect", of: "main") == .boolean(false))
        try await repository.protectBranch(named: "main")
        #expect(try await repository.branchMetadata(forKey: "protect", of: "main") == .boolean(true))
        try await repository.unprotectBranch(named: "main")
        #expect(try await repository.branchMetadata(forKey: "protect", of: "main") == .boolean(false))

        let error = await #expect(throws: LoreError.self) {
            try await repository.protectBranch(named: "missing")
        }
        #expect(error?.code == .branchNotFound)
    }

    @Test func resetBranchMovesItsLatestRevision() async throws {
        let (repository, main, feature) = try await repositoryWithFeatureBranch()
        #expect(try await repository.latestRevisions() == [feature.id, main[1].id])

        #expect(try await repository.resetBranch(to: .id(main[1].id)) == main[1].id)
        #expect(try await repository.status().revision == main[1].id)
        #expect(try repository.read("a.txt") == "Two\n")
        #expect(try await repository.branchInfo().latestRevision == main[1].id)
        #expect(try await repository.latestRevisions() == [main[1].id, feature.id, main[1].id])
        #expect(try await repository.latestRevisions(limit: 1) == [main[1].id])

        #expect(try await repository.resetBranch(named: "main", to: "main@1") == main[0].id)
        #expect(try await repository.branchInfo(named: "main").latestRevision == main[0].id)
        #expect(try await repository.latestRevisions(on: "main") == [main[0].id, main[1].id, main[0].id])
        #expect(try repository.read("a.txt") == "Two\n")

        let error = await #expect(throws: LoreError.self) {
            try await repository.latestRevisions(limit: 0)
        }
        #expect(error?.code == .invalidArguments)
    }

    @Test func latestRevisionsListsThirtyByDefault() async throws {
        let (repository, main, _) = try await repositoryWithFeatureBranch()
        // Each reset of the other branch adds an entry to its list.
        for index in 0 ..< 32 {
            try await repository.resetBranch(named: "main", to: .id(main[index % 2].id))
        }
        #expect(try await repository.latestRevisions(on: "main").count == 30)
        #expect(try await repository.latestRevisions(on: "main", limit: 40).count > 30)
    }

    @Test func branchMetadataIncludesTheBranchRecord() async throws {
        let (repository, _, feature) = try await repositoryWithFeatureBranch()
        let metadata = try await repository.branchMetadata()
        #expect(metadata["name"] == .string("feature"))
        #expect(metadata["category"] == .string("work"))
        #expect(metadata["creator"] == .string("test@example.com"))
        #expect(metadata["id"] == .binary(try #require(feature.branchID).bytes))
        #expect(try await repository.branchMetadata(of: "main")["name"] == .string("main"))
        #expect(try await repository.branchMetadata(forKey: "missing") == nil)
    }

    @Test func settingBranchMetadataNeedsAServer() async throws {
        let (repository, _, _) = try await repositoryWithFeatureBranch()
        let set = await #expect(throws: LoreError.self) {
            try await repository.setBranchMetadata(["owner": .string("alice")])
        }
        #expect(set?.code == .noRemote)
        let clear = await #expect(throws: LoreError.self) {
            try await repository.clearBranchMetadata(of: "main")
        }
        #expect(clear?.code == .noRemote)
        let clearKeys = await #expect(throws: LoreError.self) {
            try await repository.clearBranchMetadata(keys: ["owner"])
        }
        #expect(clearKeys?.code == .noRemote)
        // No keys means no library call, so the offline repository doesn't fail.
        try await repository.clearBranchMetadata(keys: [])
    }
}
