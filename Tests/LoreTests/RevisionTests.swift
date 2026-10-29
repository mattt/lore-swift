import Foundation
import Testing

@testable import Lore

@Suite struct RevisionTests {
    /// Returns an offline repository with three revisions on `main`
    /// that change `a.txt` and add `b.txt` in the second.
    private func repositoryWithHistory() async throws -> (Repository, [Revision]) {
        let repository = try await makeOfflineRepository()
        var revisions: [Revision] = []
        for (index, message) in ["One", "Two", "Three"].enumerated() {
            try repository.write("\(message)\n", to: "a.txt")
            if index == 1 {
                try repository.write("bee\n", to: "b.txt")
            }
            try await repository.stage(["."])
            revisions.append(try await repository.commit(message: message))
        }
        return (repository, revisions)
    }

    @Test func commitReturnsMetadata() async throws {
        let (repository, revisions) = try await repositoryWithHistory()
        let revision = try #require(revisions.last)
        #expect(revision.message == "Three")
        #expect(revision.creator == "test@example.com")
        #expect(abs(try #require(revision.date).timeIntervalSinceNow) < 60)
        #expect(revision.branchID == (try await repository.status().branchID))
    }

    @Test func historyListsRevisionsNewestFirst() async throws {
        let (repository, revisions) = try await repositoryWithHistory()
        let history = try await repository.history()
        #expect(history.map(\.id) == revisions.reversed().map(\.id))
        #expect(history.map(\.number) == [3, 2, 1])
        #expect(history.map(\.message) == ["Three", "Two", "One"])
        #expect(history.map(\.parents) == [[revisions[1].id], [revisions[0].id], []])
        #expect(history.allSatisfy { $0.branchID == revisions[0].branchID && $0.creator == "test@example.com" })
        #expect(history == revisions.reversed())
    }

    @Test func historyHonorsStartLimitAndDate() async throws {
        let (repository, _) = try await repositoryWithHistory()
        #expect(try await repository.history(limit: 2).map(\.number) == [3, 2])
        #expect(try await repository.history(from: "main@2").map(\.number) == [2, 1])
        #expect(try await repository.history(since: Date().addingTimeInterval(3600)).isEmpty)
        #expect(try await repository.history(since: Date().addingTimeInterval(-3600)).count == 3)
        let error = await #expect(throws: LoreError.self) {
            try await repository.history(limit: 0)
        }
        #expect(error?.code == .invalidArguments)
    }

    @Test func historyIncludesEveryRevisionSinceADateBefore1970() async throws {
        let (repository, _) = try await repositoryWithHistory()
        #expect(try await repository.history(since: Date(timeIntervalSince1970: 0)).count == 3)
        #expect(try await repository.history(since: Date(timeIntervalSince1970: -1)).count == 3)
        #expect(try await repository.history(since: .distantPast).count == 3)
        #expect(try await repository.history(since: .distantFuture).isEmpty)
    }

    @Test(arguments: [TimeInterval.infinity, -.infinity, .nan, 1e20])
    func historyRejectsDatesWithoutATimestamp(_ seconds: TimeInterval) async throws {
        let (repository, _) = try await repositoryWithHistory()
        let error = await #expect(throws: LoreError.self) {
            try await repository.history(since: Date(timeIntervalSince1970: seconds))
        }
        #expect(error?.code == .invalidArguments)
    }

    @Test func historyOfABranchContinuesIntoItsParent() async throws {
        let (repository, revisions) = try await repositoryWithHistory()
        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        try repository.write("feature\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let feature = try await repository.commit(message: "Feature")

        let history = try await repository.history()
        #expect(history.map(\.id) == [feature.id] + revisions.reversed().map(\.id))
        #expect(history.first?.branchID == feature.branchID)
        #expect(history.last?.branchID == revisions[0].branchID)
        #expect(history.first?.branchID != history.last?.branchID)

        let untilBranchPoint = try await repository.history(stoppingAtBranchPoint: true)
        #expect(untilBranchPoint.map(\.id) == [feature.id, revisions[2].id])

        #expect(try await repository.history(on: "main").map(\.id) == revisions.reversed().map(\.id))
    }

    @Test func revisionReturnsARevisionWithMetadata() async throws {
        let (repository, revisions) = try await repositoryWithHistory()
        #expect(try await repository.revision() == revisions[2])
        #expect(try await repository.revision("main@1") == revisions[0])
        #expect(try await repository.revision(.id(revisions[1].id)).message == "Two")

        let error = await #expect(throws: LoreError.self) {
            try await repository.revision("main@9")
        }
        #expect(error?.code == .revisionNotFound)
    }

    @Test func changesInARevision() async throws {
        let (repository, _) = try await repositoryWithHistory()
        try FileManager.default.removeItem(atPath: "\(repository.path)/b.txt")
        try FileManager.default.createDirectory(atPath: "\(repository.path)/docs", withIntermediateDirectories: true)
        try repository.write("read me\n", to: "docs/README")
        try repository.write("four\n", to: "a.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "Four")

        let changes = try await repository.changes()
        #expect(
            Set(changes) == [
                FileChange(path: "a.txt", action: .keep, kind: .file),
                FileChange(path: "b.txt", action: .delete, kind: .file),
                FileChange(path: "docs", action: .add, kind: .directory),
                FileChange(path: "docs/README", action: .add, kind: .file),
            ]
        )
        #expect(
            Set(try await repository.changes(in: "main@2")) == [
                FileChange(path: "a.txt", action: .keep, kind: .file),
                FileChange(path: "b.txt", action: .add, kind: .file),
            ]
        )
    }

    @Test func changesBetweenRevisions() async throws {
        let (repository, _) = try await repositoryWithHistory()
        #expect(
            Set(try await repository.changes(from: "main@1")) == [
                FileChange(path: "a.txt", action: .keep, kind: .file),
                FileChange(path: "b.txt", action: .add, kind: .file),
            ]
        )
        #expect(
            try await repository.changes(from: "main@2", to: "main@1") == [
                FileChange(path: "a.txt", action: .keep, kind: .file),
                FileChange(path: "b.txt", action: .delete, kind: .file),
            ]
        )
        #expect(
            try await repository.changes(from: "main@1", to: "main@3", paths: ["b.txt"]) == [
                FileChange(path: "b.txt", action: .add, kind: .file)
            ]
        )
        #expect(try await repository.changes(from: "main@3").isEmpty)
    }

    @Test func amendReplacesTheMessage() async throws {
        let (repository, revisions) = try await repositoryWithHistory()
        let amended = try await repository.amend(message: "Three, amended")
        #expect(amended.id != revisions[2].id)
        #expect(amended.number == 3)
        #expect(amended.parents == revisions[2].parents)
        #expect(amended.branchID == revisions[2].branchID)
        #expect(amended.message == "Three, amended")
        #expect(amended.date == revisions[2].date)
        #expect(try await repository.revision() == amended)
        #expect(try await repository.history().map(\.message) == ["Three, amended", "Two", "One"])
        #expect(try await repository.latestRevisions(limit: 2) == [amended.id, revisions[2].id])
        #expect(try await repository.changes() == (try await repository.changes(in: .id(revisions[2].id))))

        try repository.write("four\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        #expect(try await repository.commit(message: "Four").parents == [amended.id])
    }

    @Test func amendKeepsStagedChangesOutOfTheRevision() async throws {
        let (repository, revisions) = try await repositoryWithHistory()
        try repository.write("four\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let amended = try await repository.amend(message: "Three, amended")
        #expect(
            try await repository.changes(in: .id(amended.id))
                == (try await repository.changes(in: .id(revisions[2].id)))
        )

        // Lore 0.12.0 refuses to commit changes staged before an amend.
        let error = await #expect(throws: LoreError.self) {
            try await repository.commit(message: "Four")
        }
        #expect(error?.code == .internal)
        try await repository.unstage(["a.txt"])
        try await repository.stage(["a.txt"])
        let four = try await repository.commit(message: "Four")
        #expect(four.parents == [amended.id])
        #expect(try await repository.changes(in: .id(four.id)).map(\.path) == ["a.txt"])
    }

    @Test func restoreNeedsAServer() async throws {
        let (repository, _) = try await repositoryWithHistory()
        try await repository.sync(to: "main@1")
        let error = await #expect(throws: LoreError.self) {
            try await repository.restore(message: "Restore")
        }
        // Lore 0.12.0 reports this with the internal error code.
        #expect(error?.code == .internal)
    }
}

@Suite struct RevisionSearchTests {
    /// Returns an offline repository with five revisions on `main`,
    /// each with a `ticket` metadata value of `T-` and its number,
    /// that change `a.txt` to `version` and the number.
    private func repositoryWithTickets() async throws -> (Repository, [Revision]) {
        let repository = try await makeOfflineRepository()
        var revisions: [Revision] = []
        for number in 1 ... 5 {
            try repository.write("version \(number)\n", to: "a.txt")
            try await repository.stage(["a.txt"])
            try await repository.setRevisionMetadata(["ticket": .string("T-\(number)"), "points": .number(3)])
            revisions.append(try await repository.commit(message: "Revision \(number)"))
        }
        return (repository, revisions)
    }

    @Test func findRevisionByMetadata() async throws {
        let (repository, revisions) = try await repositoryWithTickets()
        #expect(try await repository.findRevision(withMetadataKey: "ticket") == revisions[4])
        #expect(try await repository.findRevision(withMetadataKey: "ticket", value: "T-2") == revisions[1])
        #expect(try await repository.findRevision(withMetadataKey: "message", value: "Revision 3") == revisions[2])
        #expect(try await repository.findRevision(withMetadataKey: "ticket", value: "T-9") == nil)
        #expect(try await repository.findRevision(withMetadataKey: "missing") == nil)
        // The library compares the stored bytes of a value as text.
        #expect(try await repository.findRevision(withMetadataKey: "points", value: "3") == nil)
        #expect(try await repository.findRevision(withMetadataKey: "points") == revisions[4])

        // The search starts at the latest revision, not the current one.
        try await repository.sync(to: "main@2")
        #expect(try await repository.findRevision(withMetadataKey: "ticket") == revisions[4])

        let error = await #expect(throws: LoreError.self) {
            try await repository.findRevision(withMetadataKey: "")
        }
        #expect(error?.code == .invalidArguments)
    }

    @Test func findRevisionByNumberContinuesIntoTheParentBranch() async throws {
        let (repository, revisions) = try await repositoryWithTickets()
        #expect(try await repository.findRevision(numbered: 3) == revisions[2])
        #expect(try await repository.findRevision(numbered: 9) == nil)

        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        try repository.write("feature\n", to: "f.txt")
        try await repository.stage(["f.txt"])
        let feature = try await repository.commit(message: "Feature")
        #expect(feature.number == 6)
        #expect(try await repository.findRevision(numbered: 6) == feature)
        #expect(try await repository.findRevision(numbered: 1) == revisions[0])
        #expect(try await repository.findRevision(withMetadataKey: "ticket", value: "T-1") == revisions[0])

        let error = await #expect(throws: LoreError.self) {
            try await repository.findRevision(numbered: 0)
        }
        #expect(error?.code == .invalidArguments)
    }

    @Test func bisectFindsTheFirstRevisionWithAChange() async throws {
        let (repository, revisions) = try await repositoryWithTickets()
        // The change appears in revision 4.
        var start: RevisionSpecifier = "main@1"
        var end: RevisionSpecifier = .latest()
        var steps: [BisectStep] = []
        while true {
            let step = try await repository.bisect(between: start, and: end)
            steps.append(step)
            #expect(try await repository.status().revision == step.revision.id)
            #expect(try repository.read("a.txt") == "version \(step.revision.number)\n")
            if step.isFinished {
                break
            }
            if step.revision.number >= 4 {
                end = .id(step.revision.id)
            } else {
                start = .id(step.revision.id)
            }
        }
        #expect(steps.map(\.revision.number) == [3, 4, 4])
        #expect(steps.map(\.startNumber) == [1, 3, 3])
        #expect(steps.map(\.endNumber) == [5, 5, 4])
        #expect(steps.map(\.isFinished) == [false, false, true])
        #expect(steps.last?.revision == revisions[3])
    }

    @Test func bisectRejectsRangesItCannotSearch() async throws {
        let (repository, _) = try await repositoryWithTickets()
        let same = await #expect(throws: LoreError.self) {
            try await repository.bisect(between: "main@3", and: "main@3")
        }
        #expect(same?.code == .internal)
        let reversed = await #expect(throws: LoreError.self) {
            try await repository.bisect(between: "main@5", and: "main@1")
        }
        #expect(reversed?.code == .internal)
        let missing = await #expect(throws: LoreError.self) {
            try await repository.bisect(between: "main@1", and: "main@9")
        }
        #expect(missing?.code == .revisionNotFound)

        try repository.write("local\n", to: "a.txt")
        let modified = await #expect(throws: LoreError.self) {
            try await repository.bisect(between: "main@1", and: "main@5")
        }
        #expect(modified?.code == .localModifications)
    }
}

@Suite struct RevisionMetadataTests {
    @Test func metadataIsRecordedByTheNextCommit() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("one\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let first = try await repository.commit(message: "One")
        #expect(try await repository.revisionMetadata() == first.metadata)
        #expect(try await repository.revisionMetadata(forKey: "message") == .string("One"))

        try repository.write("two\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let values: [String: MetadataValue] = [
            "ticket": .string("T-1"),
            "points": .number(3),
            "reviewed": .boolean(true),
            "source": .hash(Array(repeating: 0xab, count: 32)),
        ]
        try await repository.setRevisionMetadata(values)
        #expect(try await repository.revisionMetadata() == values)
        #expect(try await repository.revisionMetadata(forKey: "ticket") == .string("T-1"))
        #expect(try await repository.revisionMetadata(forKey: "message") == nil)

        let second = try await repository.commit(message: "Two")
        #expect(second.message == "Two")
        for (key, value) in values {
            #expect(second.metadata[key] == value)
            #expect(try await repository.revisionMetadata(forKey: key, of: .id(second.id)) == value)
        }
        #expect(try await repository.revisionMetadata(of: "main@2") == second.metadata)
        #expect(try await repository.revisionMetadata(of: "main@1") == first.metadata)
        #expect(try await repository.revisionMetadata(forKey: "ticket", of: "main@1") == nil)
    }

    @Test func clearRemovesTheValuesForTheNextCommit() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("one\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.setRevisionMetadata(["ticket": .string("T-1")])
        try await repository.clearRevisionMetadata()
        #expect(try await repository.revisionMetadata().isEmpty)

        let revision = try await repository.commit(message: "One")
        #expect(revision.metadata["ticket"] == nil)
        #expect(revision.message == "One")
    }

    @Test func refusesValuesTheBindingCannotSet() async throws {
        let repository = try await makeOfflineRepository()
        let error = await #expect(throws: LoreError.self) {
            try await repository.setRevisionMetadata(["data": .binary([1])])
        }
        #expect(error?.code == .notSupported)
    }
}
