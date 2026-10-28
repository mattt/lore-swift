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
        #expect(merge.parents == [main.id, try #require(result.sourceRevision)])
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

    @Test func stageMergedAddsFilesBackToTheMerge() async throws {
        let (repository, _, _) = try await repositoryWithConflictingBranches()
        try await repository.mergeBranch(named: "feature")
        try await repository.unstage(["a.txt", "c.txt"])
        for file in ["a.txt", "c.txt"] {
            let unstaged = try #require(try await repository.status(ofFile: file))
            #expect(!unstaged.isMerged && !unstaged.isStaged && !unstaged.isConflicted)
        }

        try await repository.stageMerged(["a.txt", "c.txt"])
        let a = try #require(try await repository.status(ofFile: "a.txt"))
        #expect(a.isMerged && a.isStaged && a.isConflicted)
        let c = try #require(try await repository.status(ofFile: "c.txt"))
        #expect(c.isMerged && c.isStaged && !c.isConflicted)
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
        let diff = try await repository.branchDiff(merging: "feature", into: "main")
        #expect(diff.sourceRevision == feature.id)
        #expect(diff.targetRevision == main.id)
        #expect(diff.baseRevision == main.parents.first)
        #expect(diff.changes == [BranchDiff.Change(path: "c.txt", action: .add, isAutomaticallyMerged: false)])
        #expect(diff.conflicts.map(\.source.path) == ["a.txt"])

        let reverse = try await repository.branchDiff(merging: "main", into: "feature")
        #expect(reverse.sourceRevision == main.id)
        #expect(reverse.targetRevision == feature.id)
        #expect(reverse.changes.isEmpty)
        #expect(reverse.conflicts.map(\.source.path) == ["a.txt"])

        let limited = try await repository.branchDiff(merging: "feature", into: "main", path: "c.txt")
        #expect(limited.changes.map(\.path) == ["c.txt"])
        #expect(limited.conflicts.isEmpty)

        let error = await #expect(throws: LoreError.self) {
            try await repository.branchDiff(merging: "missing", into: "main")
        }
        #expect(error?.code == .branchNotFound)
    }

    @Test func branchDiffReportsEachSideOfAConflict() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("base\n", to: "a.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "Base")
        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        try FileManager.default.removeItem(atPath: "\(repository.path)/a.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "Delete a.txt")
        try await repository.switchBranch(to: "main")
        try repository.write("main\n", to: "a.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "Main")

        let deleted = BranchDiff.Change(path: "a.txt", action: .delete, isAutomaticallyMerged: false)
        let modified = BranchDiff.Change(path: "a.txt", action: .keep, isAutomaticallyMerged: false)
        let diff = try await repository.branchDiff(merging: "feature", into: "main")
        #expect(diff.changes.isEmpty)
        #expect(diff.conflicts == [BranchDiff.Conflict(source: deleted, target: modified)])
        let reverse = try await repository.branchDiff(merging: "main", into: "feature")
        #expect(reverse.conflicts == [BranchDiff.Conflict(source: modified, target: deleted)])
    }

    /// Returns an offline repository where `feature` and `main`
    /// both change `a.txt` and `b.txt`,
    /// change `auto.txt` in different places,
    /// and `feature` adds `c.txt` and `d.txt`.
    private func repositoryWithSeveralChanges() async throws -> Repository {
        let repository = try await makeOfflineRepository()
        func commit(_ text: String, auto: String, message: String) async throws {
            try repository.write(text, to: "a.txt")
            try repository.write(text, to: "b.txt")
            try repository.write(auto, to: "auto.txt")
            try await repository.stage(["."])
            try await repository.commit(message: message)
        }
        try await commit("base\n", auto: "1\n2\n3\n4\n5\n6\n", message: "Base")
        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        try repository.write("sea\n", to: "c.txt")
        try repository.write("dee\n", to: "d.txt")
        try await commit("feature\n", auto: "1 feature\n2\n3\n4\n5\n6\n", message: "Feature")
        try await repository.switchBranch(to: "main")
        try await commit("main\n", auto: "1\n2\n3\n4\n5\n6 main\n", message: "Main")
        return repository
    }

    @Test func branchDiffPredictsTheMerge() async throws {
        let repository = try await repositoryWithSeveralChanges()
        let diff = try await repository.branchDiff(merging: "feature", into: "main")
        #expect(
            diff.changes.sorted { $0.path < $1.path } == [
                BranchDiff.Change(path: "auto.txt", action: .keep, isAutomaticallyMerged: true),
                BranchDiff.Change(path: "c.txt", action: .add, isAutomaticallyMerged: false),
                BranchDiff.Change(path: "d.txt", action: .add, isAutomaticallyMerged: false),
            ]
        )
        #expect(diff.conflicts.map(\.source.path).sorted() == ["a.txt", "b.txt"])
        #expect(diff.conflicts.allSatisfy { $0.source == $0.target && $0.source.action == .keep })

        // Without automatic merging, a file that both branches changed is a conflict.
        let plain = try await repository.branchDiff(merging: "feature", into: "main", mergingAutomatically: false)
        #expect(plain.changes.map(\.path).sorted() == ["c.txt", "d.txt"])
        #expect(plain.conflicts.map(\.source.path).sorted() == ["a.txt", "auto.txt", "b.txt"])

        let result = try await repository.mergeBranch(named: "feature")
        #expect(result.revision == nil)
        #expect(result.conflicts.sorted() == diff.conflicts.map(\.source.path).sorted())
        #expect(try repository.read("auto.txt") == "1 feature\n2\n3\n4\n5\n6 main\n")
        let status = try await repository.status()
        #expect(status.files.map(\.path).sorted() == ["a.txt", "auto.txt", "b.txt", "c.txt", "d.txt"])
        #expect(status.files.allSatisfy { $0.isMerged })
        #expect(status.files.filter(\.isConflicted).map(\.path).sorted() == ["a.txt", "b.txt"])
        #expect(status.files.first { $0.path == "auto.txt" }?.conflictResolution == .merged)

        try await repository.resolveConflicts(in: ["a.txt"], keeping: .mine)
        // The file information doesn't report the conflicts of a merge in progress.
        let info = try await repository.fileInfo(of: ["a.txt", "auto.txt", "b.txt"])
        #expect(info.count == 3)
        #expect(info.allSatisfy { !$0.isConflicted })
        let error = await #expect(throws: LoreError.self) {
            try await repository.commit(message: "Merge feature")
        }
        #expect(error?.code == .conflict)
        #expect(try await repository.status(ofFile: "b.txt")?.isConflicted == true)

        #expect(try await repository.resolveConflicts(in: ["b.txt"], keeping: .theirs) == ["b.txt"])
        let merge = try await repository.commit(message: "Merge feature")
        #expect(try repository.read("a.txt") == "main\n")
        #expect(try repository.read("b.txt") == "feature\n")
        #expect(Set(try await repository.changes(in: .id(merge.id)).map(\.path)).isSuperset(of: ["c.txt", "d.txt"]))
    }

    @Test func resolvingADirectoryWithASideReplacesEveryMergedFile() async throws {
        let repository = try await repositoryWithSeveralChanges()
        try await repository.mergeBranch(named: "feature")
        let resolved = try await repository.resolveConflicts(in: ["."], keeping: .mine)
        #expect(resolved.sorted() == ["a.txt", "auto.txt", "b.txt", "c.txt", "d.txt"])
        #expect(try repository.read("a.txt") == "main\n")
        #expect(try repository.read("b.txt") == "main\n")
        // The automatic merge and the added files are replaced too.
        #expect(try repository.read("auto.txt") == "1\n2\n3\n4\n5\n6 main\n")
        #expect(!repository.exists("c.txt"))
        let status = try await repository.status()
        for file in ["a.txt", "auto.txt", "b.txt"] {
            let entry = try #require(status.files.first { $0.path == file })
            #expect(!entry.isConflicted)
            #expect(entry.conflictResolution == .mine)
        }
        #expect(status.files.filter(\.isConflicted).map(\.path).sorted() == ["c.txt", "d.txt"])
    }

    @Test func resetToTheLastMerge() async throws {
        let repository = try await makeOfflineRepository()
        func commit(_ files: [String: String], _ message: String) async throws {
            for (file, text) in files {
                try repository.write(text, to: file)
            }
            try await repository.stage(Array(files.keys))
            try await repository.commit(message: message)
        }
        try await commit(["a.txt": "base\n", "one.txt": "base\n"], "Base")
        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        try await commit(["a.txt": "feature\n"], "Feature")
        try await repository.createBranch(named: "child")
        try await repository.switchBranch(to: "child")
        try await commit(["a.txt": "child\n"], "Child")
        // Both ancestors of `child` move on after it branches.
        try await repository.switchBranch(to: "feature")
        try await commit(["a.txt": "feature later\n"], "Feature later")
        try await repository.switchBranch(to: "main")
        try await commit(["a.txt": "main\n", "one.txt": "main one\n"], "Main")
        try await repository.switchBranch(to: "child")

        // Without a merge, the files get their content
        // at the revision of the branch that `child` descends from.
        try repository.write("scratch\n", to: "a.txt")
        #expect(try await repository.reset(["a.txt"], toLastMergeFrom: "feature").map(\.path) == ["a.txt"])
        #expect(try repository.read("a.txt") == "feature\n")
        #expect(try await repository.reset(["a.txt"], toLastMergeFrom: "main").map(\.path) == ["a.txt"])
        #expect(try repository.read("a.txt") == "base\n")

        try await repository.reset(["a.txt"])
        try await repository.mergeBranch(named: "main")
        try repository.write("main and child\n", to: "a.txt")
        try await repository.resolveConflicts(in: ["a.txt"])
        try await repository.commit(message: "Merge main")
        // Both branches move on after the merge.
        try await commit(["a.txt": "child later\n", "one.txt": "child one later\n"], "Child later")
        try await repository.switchBranch(to: "main")
        try await commit(["a.txt": "main later\n", "one.txt": "main one later\n"], "Main later")
        try await repository.switchBranch(to: "child")

        let expected: [(MergeSide, [String])] = [
            (.merged, ["main and child\n", "main one\n"]),
            (.mine, ["child\n", "base\n"]),
            (.theirs, ["main\n", "main one\n"]),
        ]
        for (side, contents) in expected {
            try repository.write("scratch\n", to: "a.txt")
            try repository.write("scratch\n", to: "one.txt")
            let reset = try await repository.reset(["a.txt", "one.txt"], toLastMergeFrom: "main", keeping: side)
            #expect(reset.map(\.path).sorted() == ["a.txt", "one.txt"])
            #expect([try repository.read("a.txt"), try repository.read("one.txt")] == contents)
        }

        // For a directory, Lore 0.11.0 restores the content at the branch point
        // instead of the content of the merge.
        for deletingUntrackedFiles in [false, true] {
            try repository.write("scratch\n", to: "a.txt")
            try repository.write("scratch\n", to: "one.txt")
            try repository.write("untracked\n", to: "untracked.txt")
            let reset = try await repository.reset(
                ["."],
                toLastMergeFrom: "main",
                deletingUntrackedFiles: deletingUntrackedFiles
            )
            #expect(reset.map(\.path).sorted() == ["a.txt", "one.txt"])
            #expect([try repository.read("a.txt"), try repository.read("one.txt")] == ["base\n", "base\n"])
            #expect(repository.exists("untracked.txt") == !deletingUntrackedFiles)
        }

        for branch in ["child", "missing"] {
            let error = await #expect(throws: LoreError.self) {
                try await repository.reset(["a.txt"], toLastMergeFrom: branch)
            }
            #expect(error?.code == .branchNotFound)
        }
    }

    @Test func mergeIntoNeedsAServer() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("base\n", to: "a.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "Base")
        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        try repository.write("feature\n", to: "a.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "Feature")
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

    /// Reverts `main@2` right after a merge commit,
    /// which conflicts in `a.txt`.
    private func revertAfterAMerge() async throws -> (Repository, merge: Revision) {
        let (repository, _, _) = try await repositoryWithConflictingBranches()
        try await repository.mergeBranch(named: "feature")
        try await repository.resolveConflicts(in: ["a.txt"], keeping: .theirs)
        let merge = try await repository.commit(message: "Merge feature")
        let result = try await repository.revert("main@2")
        #expect(result.sourceRevision != nil)
        #expect(result.conflicts == ["a.txt"])
        #expect(result.revision == nil)
        return (repository, merge)
    }

    @Test func resolveARevertRightAfterAMerge() async throws {
        let (repository, merge) = try await revertAfterAMerge()
        #expect(try await repository.resolveConflicts(in: ["a.txt"], keeping: .mine) == ["a.txt"])
        let revert = try await repository.commit(message: "Revert main")
        #expect(revert.parents == [merge.id])
        #expect(try repository.read("a.txt") == "feature\n")
    }

    @Test func abortARevertRightAfterAMerge() async throws {
        let (repository, merge) = try await revertAfterAMerge()
        try await repository.abortMerge()
        #expect(try repository.read("a.txt") == "feature\n")
        let status = try await repository.status()
        #expect(status.revision == merge.id)
        #expect(status.files.isEmpty)
    }

    @Test func resolveARevertThroughADirectory() async throws {
        let repository = try await makeOfflineRepository()
        for message in ["one", "two", "three"] {
            try repository.write("\(message)\n", to: "a.txt")
            try repository.write("b \(message)\n", to: "b.txt")
            try repository.write(message == "two" ? "c two\n" : "c\n", to: "c.txt")
            try await repository.stage(["."])
            try await repository.commit(message: message)
        }
        #expect(try await repository.revert("main@2").conflicts.sorted() == ["a.txt", "b.txt"])

        // Resolving a directory with a side also replaces `c.txt`,
        // which the revert changed without conflict,
        // and Lore 0.11.0 then reports `c.txt` as in conflict.
        #expect(
            try await repository.resolveConflicts(in: ["."], keeping: .theirs).sorted() == ["a.txt", "b.txt", "c.txt"]
        )
        #expect(try repository.read("a.txt") == "one\n")
        #expect(try repository.read("b.txt") == "b one\n")
        let status = try await repository.status()
        #expect(status.files.filter(\.isConflicted).map(\.path) == ["c.txt"])
        #expect(status.files.first { $0.path == "a.txt" }?.conflictResolution == .theirs)
        #expect(status.files.first { $0.path == "b.txt" }?.conflictResolution == .theirs)
    }

    @Test func unresolveRestartAndAbortARevert() async throws {
        let (repository, revisions) = try await repositoryWithHistory()
        try await repository.revert("main@2")
        try await repository.resolveConflicts(in: ["a.txt"], keeping: .theirs)
        #expect(try await repository.unresolveConflicts(in: ["a.txt"]) == ["a.txt"])
        #expect(try await repository.status(ofFile: "a.txt")?.isConflicted == true)

        try await repository.restartMerge(of: ["a.txt"])
        #expect(try repository.read("a.txt").hasPrefix("<<<<<<< ours\nthree\n"))
        let stage = await #expect(throws: LoreError.self) {
            try await repository.stageMerged(["a.txt"])
        }
        #expect(stage?.code == .internal)

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

        try await repository.switchBranch(to: "feature")
        try repository.write("dee\n", to: "d.txt")
        try await repository.stage(["d.txt"])
        let second = try await repository.commit(message: "Add d.txt")
        try await repository.switchBranch(to: "main")
        let named = try #require(try await repository.cherryPick(.id(second.id), message: "Picked").revision)
        #expect(named.message == "Picked")
        #expect(named.parents == [pick.id])
        #expect(named.metadata["cherry-picked-from"] == .hash(second.id.bytes))

        let current = await #expect(throws: LoreError.self) {
            try await repository.cherryPick(.id(named.id))
        }
        #expect(current?.code == .internal)
    }

    @Test func cherryPickWithoutCommitting() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("base\n", to: "a.txt")
        try await repository.stage(["."])
        let base = try await repository.commit(message: "Base")
        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        var picks: [Revision] = []
        for file in ["c.txt", "d.txt"] {
            try repository.write("\(file)\n", to: file)
            try await repository.stage([file])
            picks.append(try await repository.commit(message: "Add \(file)"))
        }
        try await repository.switchBranch(to: "main")

        let result = try await repository.cherryPick(.id(picks[0].id), message: "Unused", committing: false)
        #expect(result.sourceRevision == picks[0].id)
        #expect(result.revision == nil)
        #expect(result.conflicts.isEmpty)
        let file = try #require(try await repository.status(ofFile: "c.txt"))
        #expect(file.isMerged && file.isStaged && !file.isConflicted)
        let stage = await #expect(throws: LoreError.self) {
            try await repository.stageMerged(["c.txt"])
        }
        #expect(stage?.code == .internal)
        let abort = await #expect(throws: LoreError.self) {
            try await repository.abortMerge()
        }
        #expect(abort?.code == .internal)

        let pick = try await repository.commit(message: "Pick c.txt")
        #expect(pick.parents == [base.id])
        #expect(pick.message == "Pick c.txt")
        #expect(pick.metadata["cherry-picked-from"] == .hash(picks[0].id.bytes))

        try await repository.cherryPick(.id(picks[1].id), committing: false)
        #expect(repository.exists("d.txt"))
        try await repository.sync(discardingLocalChanges: true)
        #expect(!repository.exists("d.txt"))
        let status = try await repository.status()
        #expect(status.revision == pick.id)
        #expect(status.files.isEmpty)
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
