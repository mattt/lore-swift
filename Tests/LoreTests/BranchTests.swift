import Testing

@testable import Lore

@Suite struct BranchTests {
    @Test func createListAndSwitch() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("hello\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let revision = try await repository.commit(message: "First")

        let main = try #require(try await repository.branches().first)
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
        // Lore 0.11.0 reports this with the internal error code.
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
}
