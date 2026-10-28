import Foundation
import Testing

@testable import Lore

/// Returns an offline repository where `feature` and `main`
/// both change `a.txt` from `base`,
/// `feature` adds `c.txt`,
/// and `main` is the current branch.
func repositoryWithConflictingBranches() async throws -> (Repository, main: Revision, feature: Revision) {
    let repository = try await makeOfflineRepository()
    try repository.write("base\n", to: "a.txt")
    try repository.write("bee\n", to: "b.txt")
    try await repository.stage(["."])
    try await repository.commit(message: "Base")
    try await repository.createBranch(named: "feature")
    try await repository.switchBranch(to: "feature")
    try repository.write("feature\n", to: "a.txt")
    try repository.write("sea\n", to: "c.txt")
    try await repository.stage(["."])
    let feature = try await repository.commit(message: "Feature")
    try await repository.switchBranch(to: "main")
    try repository.write("main\n", to: "a.txt")
    try await repository.stage(["a.txt"])
    let main = try await repository.commit(message: "Main")
    return (repository, main, feature)
}

extension Repository {
    /// Returns whether a file exists in the repository directory.
    func exists(_ file: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(path)/\(file)")
    }

    /// Returns the status of a file, or `nil` if it has no pending change.
    func status(ofFile file: String) async throws -> FileStatus? {
        try await status().files.first { $0.path == file }
    }
}

let conflictMarkers = "<<<<<<< ours\nmain\n||||||| original\nbase\n=======\nfeature\n>>>>>>> theirs\n"

@Suite struct MergeTests {
    @Test func mergeWithoutConflictsCommits() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("base\n", to: "a.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "Base")
        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        try repository.write("sea\n", to: "c.txt")
        try await repository.stage(["."])
        let feature = try await repository.commit(message: "Feature")
        try await repository.switchBranch(to: "main")
        try repository.write("bee\n", to: "b.txt")
        try await repository.stage(["."])
        let main = try await repository.commit(message: "Main")

        let result = try await repository.mergeBranch(named: "feature", message: "Merge feature")
        #expect(result.sourceRevision == feature.id)
        #expect(result.conflicts.isEmpty)
        let merge = try #require(result.revision)
        #expect(merge.number == 3)
        #expect(merge.parents == [main.id, feature.id])
        #expect(merge.branchID == main.branchID)
        #expect(merge.message == "Merge feature")
        #expect(merge.metadata["merged-by"] == .string("test@example.com"))
        #expect(try repository.read("c.txt") == "sea\n")
        #expect(try await repository.status().files.isEmpty)
        #expect(try await repository.revision() == merge)
    }

    @Test func mergeCombinesChangesInDifferentPlaces() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("1\n2\n3\n4\n5\n6\n", to: "a.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "Base")
        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        try repository.write("1 feature\n2\n3\n4\n5\n6\n", to: "a.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "Feature")
        try await repository.switchBranch(to: "main")
        try repository.write("1\n2\n3\n4\n5\n6 main\n", to: "a.txt")
        try await repository.stage(["."])
        let main = try await repository.commit(message: "Main")

        let result = try await repository.mergeBranch(named: "feature", committing: false)
        #expect(result.conflicts.isEmpty)
        #expect(result.revision == nil)
        #expect(try repository.read("a.txt") == "1 feature\n2\n3\n4\n5\n6 main\n")
        let file = try #require(try await repository.status(ofFile: "a.txt"))
        #expect(file.isMerged)
        #expect(file.isStaged)
        #expect(!file.isConflicted)
        #expect(file.conflictResolution == .merged)

        let merge = try await repository.commit(message: "Merge feature")
        #expect(merge.parents == [main.id, result.sourceRevision])
        #expect(merge.message == "Merge feature")
    }

    @Test func conflictingMergeWritesEachVersion() async throws {
        let (repository, main, feature) = try await repositoryWithConflictingBranches()
        let result = try await repository.mergeBranch(named: "feature", message: "Merge feature")
        #expect(result.sourceRevision == feature.id)
        #expect(result.revision == nil)
        #expect(result.conflicts == ["a.txt"])
        #expect(try repository.read("a.txt") == conflictMarkers)
        #expect(try repository.read("a.txt~base") == "base\n")
        #expect(try repository.read("a.txt~mine") == "main\n")
        #expect(try repository.read("a.txt~theirs") == "feature\n")
        #expect(try repository.read("c.txt") == "sea\n")

        let status = try await repository.status()
        #expect(status.revision == main.id)
        let a = try #require(status.files.first { $0.path == "a.txt" })
        #expect(a.isMerged && a.isStaged && a.isConflicted)
        #expect(a.conflictResolution == nil)
        let c = try #require(status.files.first { $0.path == "c.txt" })
        #expect(c.isMerged && c.isStaged && !c.isConflicted)
        #expect(c.action == .add)
        #expect(c.conflictResolution == nil)

        let error = await #expect(throws: LoreError.self) {
            try await repository.commit(message: "Merge feature")
        }
        #expect(error?.code == .conflict)
        let again = await #expect(throws: LoreError.self) {
            try await repository.mergeBranch(named: "feature")
        }
        #expect(again?.code == .internal)
    }

    @Test(arguments: [MergeSide.mine, .theirs])
    func resolveKeepingASide(_ side: MergeSide) async throws {
        let (repository, main, feature) = try await repositoryWithConflictingBranches()
        try await repository.mergeBranch(named: "feature")

        #expect(try await repository.resolveConflicts(in: ["a.txt"], keeping: side) == ["a.txt"])
        #expect(try repository.read("a.txt") == (side == .mine ? "main\n" : "feature\n"))
        let file = try #require(try await repository.status(ofFile: "a.txt"))
        #expect(!file.isConflicted)
        #expect(file.conflictResolution == side)

        let merge = try await repository.commit(message: "Merge feature")
        #expect(merge.parents == [main.id, feature.id])
        #expect(try repository.read("a.txt") == (side == .mine ? "main\n" : "feature\n"))
        #expect(!repository.exists("a.txt~mine"))
        #expect(!repository.exists("a.txt~theirs"))
        #expect(!repository.exists("a.txt~base"))
        #expect(try await repository.status().files.isEmpty)
    }

    @Test func resolveKeepingTheMergedFile() async throws {
        let (repository, main, feature) = try await repositoryWithConflictingBranches()
        try await repository.mergeBranch(named: "feature")

        // The library skips a file that still has conflict markers.
        #expect(try await repository.resolveConflicts(in: ["a.txt"]).isEmpty)
        #expect(try await repository.status(ofFile: "a.txt")?.isConflicted == true)

        try repository.write("main and feature\n", to: "a.txt")
        #expect(try await repository.resolveConflicts(in: ["."]) == ["a.txt"])
        let file = try #require(try await repository.status(ofFile: "a.txt"))
        #expect(!file.isConflicted)
        #expect(file.conflictResolution == .merged)

        let merge = try await repository.commit(message: "Merge feature")
        #expect(merge.parents == [main.id, feature.id])
        #expect(try repository.read("a.txt") == "main and feature\n")
        #expect(try await repository.changes(from: "main@2", paths: ["a.txt"]).map(\.path) == ["a.txt"])
    }

    @Test func unresolveAndRestart() async throws {
        let (repository, _, _) = try await repositoryWithConflictingBranches()
        try await repository.mergeBranch(named: "feature")
        try await repository.resolveConflicts(in: ["a.txt"], keeping: .theirs)

        #expect(try await repository.unresolveConflicts(in: ["a.txt"]) == ["a.txt"])
        #expect(try repository.read("a.txt") == "feature\n")
        let unresolved = try #require(try await repository.status(ofFile: "a.txt"))
        #expect(unresolved.isConflicted)
        #expect(unresolved.conflictResolution == nil)

        try await repository.resolveConflicts(in: ["a.txt"], keeping: .mine)
        try await repository.restartMerge(of: ["a.txt"])
        #expect(try repository.read("a.txt") == conflictMarkers)
        #expect(try await repository.status(ofFile: "a.txt")?.isConflicted == true)
    }

    @Test func abortRestoresTheWorkingDirectory() async throws {
        let (repository, main, _) = try await repositoryWithConflictingBranches()
        try repository.write("unrelated\n", to: "b.txt")
        try await repository.mergeBranch(named: "feature")
        try await repository.resolveConflicts(in: ["a.txt"], keeping: .theirs)

        try await repository.abortMerge()
        #expect(try repository.read("a.txt") == "main\n")
        #expect(try repository.read("b.txt") == "unrelated\n")
        #expect(!repository.exists("c.txt"))
        #expect(!repository.exists("a.txt~mine"))
        let status = try await repository.status()
        #expect(status.revision == main.id)
        #expect(status.files.map(\.path) == ["b.txt"])
        #expect(status.files.allSatisfy { !$0.isMerged && !$0.isStaged })
    }

    @Test func stageMergedAddsAFileBackToTheMerge() async throws {
        let (repository, _, _) = try await repositoryWithConflictingBranches()
        try await repository.mergeBranch(named: "feature")
        try await repository.unstage(["c.txt"])
        let unstaged = try #require(try await repository.status(ofFile: "c.txt"))
        #expect(!unstaged.isMerged && !unstaged.isStaged)

        try await repository.stageMerged(["c.txt"])
        let staged = try #require(try await repository.status(ofFile: "c.txt"))
        #expect(staged.isMerged && staged.isStaged && !staged.isConflicted)
    }

    @Test func operationsWithoutAMergeThrow() async throws {
        let (repository, _, _) = try await repositoryWithConflictingBranches()
        let resolve = await #expect(throws: LoreError.self) {
            try await repository.resolveConflicts(in: ["a.txt"])
        }
        #expect(resolve?.code == .internal)
        let abort = await #expect(throws: LoreError.self) {
            try await repository.abortMerge()
        }
        #expect(abort?.code == .internal)
        let stage = await #expect(throws: LoreError.self) {
            try await repository.stageMerged(["a.txt"])
        }
        #expect(stage?.code == .internal)
        let missing = await #expect(throws: LoreError.self) {
            try await repository.mergeBranch(named: "missing")
        }
        #expect(missing?.code == .branchNotFound)
    }

    @Test func branchDiffReportsChangesAndConflicts() async throws {
        let (repository, main, feature) = try await repositoryWithConflictingBranches()
        let diff = try await repository.branchDiff(from: "feature", to: "main")
        #expect(diff.sourceRevision == feature.id)
        #expect(diff.targetRevision == main.id)
        #expect(diff.baseRevision == main.parents.first)
        #expect(
            diff.changes == [
                BranchDiff.Change(path: "c.txt", action: .add, isAutomaticallyMerged: false)
            ]
        )
        let change = BranchDiff.Change(path: "a.txt", action: .keep, isAutomaticallyMerged: false)
        #expect(diff.conflicts == [BranchDiff.Conflict(source: change, target: change)])

        let reverse = try await repository.branchDiff(from: "main", to: "feature")
        #expect(reverse.changes.isEmpty)
        #expect(reverse.conflicts.map(\.source.path) == ["a.txt"])

        let limited = try await repository.branchDiff(from: "feature", to: "main", path: "c.txt")
        #expect(limited.changes.map(\.path) == ["c.txt"])
        #expect(limited.conflicts.isEmpty)

        let error = await #expect(throws: LoreError.self) {
            try await repository.branchDiff(from: "missing", to: "main")
        }
        #expect(error?.code == .branchNotFound)
    }

    @Test func branchDiffCanMergeAutomatically() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("1\n2\n3\n4\n5\n6\n", to: "a.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "Base")
        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        try repository.write("1 feature\n2\n3\n4\n5\n6\n", to: "a.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "Feature")
        try await repository.switchBranch(to: "main")
        try repository.write("1\n2\n3\n4\n5\n6 main\n", to: "a.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "Main")

        let plain = try await repository.branchDiff(from: "feature", to: "main")
        #expect(plain.changes.isEmpty)
        #expect(plain.conflicts.map(\.source.path) == ["a.txt"])

        let merged = try await repository.branchDiff(from: "feature", to: "main", mergingAutomatically: true)
        #expect(merged.changes == [BranchDiff.Change(path: "a.txt", action: .keep, isAutomaticallyMerged: true)])
        #expect(merged.conflicts.isEmpty)
    }

    @Test func resetToTheLastMerge() async throws {
        let (repository, _, _) = try await repositoryWithConflictingBranches()
        try await repository.switchBranch(to: "feature")
        try await repository.mergeBranch(named: "main")
        try await repository.resolveConflicts(in: ["a.txt"], keeping: .mine)
        try await repository.commit(message: "Merge main")
        try repository.write("scratch\n", to: "a.txt")

        let reset = try await repository.reset(["a.txt"], toLastMergeFrom: "main")
        #expect(reset.map(\.path) == ["a.txt"])
        #expect(try repository.read("a.txt") == "feature\n")
        try await repository.reset(["a.txt"], toLastMergeFrom: "main", keeping: .theirs)
        #expect(try repository.read("a.txt") == "main\n")
        try await repository.reset(["a.txt"], toLastMergeFrom: "main", keeping: .mine)
        #expect(try repository.read("a.txt") == "feature\n")

        let error = await #expect(throws: LoreError.self) {
            try await repository.reset(["a.txt"], toLastMergeFrom: "feature")
        }
        #expect(error?.code == .branchNotFound)
    }

    @Test func mergeIntoNeedsAServer() async throws {
        let (repository, _, _) = try await repositoryWithConflictingBranches()
        try await repository.switchBranch(to: "feature")
        let error = await #expect(throws: LoreError.self) {
            try await repository.mergeBranch(into: "main", message: "Merge")
        }
        // Lore 0.11.0 reports this with the internal error code.
        #expect(error?.code == .internal)
    }
}

@Suite struct RevertTests {
    /// Returns an offline repository whose three revisions
    /// write `one`, `two`, and `three` to `a.txt`,
    /// and whose second revision adds `b.txt`.
    private func repositoryWithHistory() async throws -> (Repository, [Revision]) {
        let repository = try await makeOfflineRepository()
        var revisions: [Revision] = []
        for (index, message) in ["one", "two", "three"].enumerated() {
            try repository.write("\(message)\n", to: "a.txt")
            if index == 1 {
                try repository.write("bee\n", to: "b.txt")
            }
            try await repository.stage(["."])
            revisions.append(try await repository.commit(message: message))
        }
        return (repository, revisions)
    }

    @Test func revertWithoutConflictsCommits() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("one\n", to: "a.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "One")
        try repository.write("bee\n", to: "b.txt")
        try await repository.stage(["."])
        let second = try await repository.commit(message: "Two")

        let result = try await repository.revert("main@2", message: "Revert two")
        #expect(result.sourceRevision == second.id)
        #expect(result.conflicts.isEmpty)
        let revert = try #require(result.revision)
        #expect(revert.number == 3)
        #expect(revert.parents == [second.id])
        #expect(revert.message == "Revert two")
        #expect(revert.metadata["reverted-from"] == .hash(second.id.bytes))
        #expect(!repository.exists("b.txt"))
        #expect(try await repository.status().files.isEmpty)

        let error = await #expect(throws: LoreError.self) {
            try await repository.revert("main@9")
        }
        #expect(error?.code == .revisionNotFound)
    }

    @Test func revertWithoutCommittingStagesTheChanges() async throws {
        let (repository, revisions) = try await repositoryWithHistory()
        let result = try await repository.revert(.id(revisions[2].id), committing: false)
        #expect(result.revision == nil)
        #expect(try repository.read("a.txt") == "two\n")
        let file = try #require(try await repository.status(ofFile: "a.txt"))
        #expect(file.isMerged && file.isStaged && !file.isConflicted)

        try await repository.abortMerge()
        #expect(try repository.read("a.txt") == "three\n")
        #expect(try await repository.status().files.isEmpty)
    }

    @Test(arguments: [MergeSide.merged, .mine, .theirs])
    func resolveARevert(_ side: MergeSide) async throws {
        let (repository, revisions) = try await repositoryWithHistory()
        let result = try await repository.revert("main@2")
        #expect(result.conflicts == ["a.txt"])
        #expect(result.revision == nil)
        // Reverting `two` to `one` conflicts with `three`.
        #expect(try repository.read("a.txt~mine") == "three\n")
        #expect(try repository.read("a.txt~theirs") == "one\n")
        #expect(!repository.exists("b.txt"))
        #expect(try await repository.status(ofFile: "a.txt")?.isConflicted == true)

        let expected =
            switch side {
            case .merged: "one, three\n"
            case .mine: "three\n"
            case .theirs: "one\n"
            }
        if side == .merged {
            try repository.write(expected, to: "a.txt")
        }
        #expect(try await repository.resolveConflicts(in: ["a.txt"], keeping: side) == ["a.txt"])
        #expect(try await repository.status(ofFile: "a.txt")?.conflictResolution == side)

        let revert = try await repository.commit(message: "Revert two")
        #expect(revert.parents == [revisions[2].id])
        #expect(revert.metadata["reverted-from"] == .hash(revisions[1].id.bytes))
        #expect(try repository.read("a.txt") == expected)
    }

    @Test func resolveARevertOfAMerge() async throws {
        let (repository, _, _) = try await repositoryWithConflictingBranches()
        try await repository.mergeBranch(named: "feature")
        try await repository.resolveConflicts(in: ["a.txt"], keeping: .theirs)
        let merge = try await repository.commit(message: "Merge feature")
        try repository.write("later\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let later = try await repository.commit(message: "Later")

        let result = try await repository.revert(.id(merge.id))
        #expect(result.conflicts == ["a.txt"])
        // Clearing the metadata of the next commit removes `reverted-from`,
        // which doesn't stop the revert's conflicts from being resolved.
        try await repository.clearRevisionMetadata()
        #expect(try await repository.resolveConflicts(in: ["a.txt"], keeping: .mine) == ["a.txt"])
        let revert = try await repository.commit(message: "Revert the merge")
        #expect(revert.parents == [later.id])
        #expect(try repository.read("a.txt") == "later\n")
        #expect(!repository.exists("c.txt"))
    }

    @Test func unresolveRestartAndAbortARevert() async throws {
        let (repository, revisions) = try await repositoryWithHistory()
        try await repository.revert("main@2")
        try await repository.resolveConflicts(in: ["a.txt"], keeping: .theirs)
        #expect(try await repository.unresolveConflicts(in: ["a.txt"]) == ["a.txt"])
        #expect(try await repository.status(ofFile: "a.txt")?.isConflicted == true)

        try await repository.restartMerge(of: ["a.txt"])
        #expect(try repository.read("a.txt").hasPrefix("<<<<<<< ours\nthree\n"))

        try await repository.abortMerge()
        #expect(try repository.read("a.txt") == "three\n")
        #expect(try repository.read("b.txt") == "bee\n")
        #expect(!repository.exists("a.txt~theirs"))
        let status = try await repository.status()
        #expect(status.revision == revisions[2].id)
        #expect(status.files.isEmpty)
    }
}

@Suite struct CherryPickTests {
    @Test func cherryPickWithoutConflictsCommits() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("base\n", to: "a.txt")
        try await repository.stage(["."])
        let base = try await repository.commit(message: "Base")
        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        try repository.write("sea\n", to: "c.txt")
        try await repository.stage(["."])
        let feature = try await repository.commit(message: "Add c.txt")
        try await repository.switchBranch(to: "main")

        let result = try await repository.cherryPick("feature@LATEST")
        #expect(result.sourceRevision == feature.id)
        #expect(result.conflicts.isEmpty)
        let pick = try #require(result.revision)
        #expect(pick.number == 2)
        #expect(pick.parents == [base.id])
        #expect(pick.branchID == base.branchID)
        #expect(pick.message == "Add c.txt")
        #expect(pick.metadata["cherry-picked-from"] == .hash(feature.id.bytes))
        #expect(try repository.read("c.txt") == "sea\n")

        let current = await #expect(throws: LoreError.self) {
            try await repository.cherryPick(.id(pick.id))
        }
        #expect(current?.code == .internal)
    }

    @Test func conflictingCherryPickCanOnlyBeDiscarded() async throws {
        let (repository, main, feature) = try await repositoryWithConflictingBranches()
        let result = try await repository.cherryPick(.id(feature.id), message: "Pick")
        #expect(result.sourceRevision == feature.id)
        #expect(result.revision == nil)
        #expect(result.conflicts == ["a.txt"])
        #expect(try repository.read("a.txt") == conflictMarkers)
        #expect(try await repository.status(ofFile: "a.txt")?.isConflicted == true)

        let resolve = await #expect(throws: LoreError.self) {
            try await repository.resolveConflicts(in: ["a.txt"], keeping: .theirs)
        }
        #expect(resolve?.code == .internal)
        let abort = await #expect(throws: LoreError.self) {
            try await repository.abortMerge()
        }
        #expect(abort?.code == .internal)

        try await repository.sync(discardingLocalChanges: true)
        #expect(try repository.read("a.txt") == "main\n")
        #expect(!repository.exists("c.txt"))
        let status = try await repository.status()
        #expect(status.revision == main.id)
        #expect(status.files.isEmpty)
        // The files with each version remain.
        #expect(repository.exists("a.txt~theirs"))
    }
}
