import Foundation
import Testing

@testable import Lore

@Suite struct FileTests {
    /// Returns an offline repository whose first revision adds `a.txt` and `b.txt`
    /// and whose second revision changes `a.txt`.
    private func repositoryWithTwoRevisions() async throws -> Repository {
        let repository = try await makeOfflineRepository()
        try repository.write("one\n", to: "a.txt")
        try repository.write("bee\n", to: "b.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "One")
        try repository.write("two, longer\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "Two")
        return repository
    }

    @Test func historyListsTheRevisionsThatChangedAFile() async throws {
        let repository = try await repositoryWithTwoRevisions()
        let history = try await repository.history(of: "a.txt")
        #expect(history.map(\.revision.number) == [2, 1])
        #expect(history.map(\.revision.message) == ["Two", "One"])
        #expect(history.map(\.action) == [.keep, .add])
        #expect(history.map(\.size) == [12, 4])
        #expect(history.allSatisfy { $0.path == "a.txt" && $0.previousPath == nil })
        #expect(history.first?.revision == (try await repository.revision()))

        #expect(try await repository.history(of: "b.txt").map(\.revision.number) == [1])
        #expect(try await repository.history(of: "a.txt", limit: 1).map(\.revision.number) == [2])
        #expect(try await repository.history(of: "a.txt", from: "main@1").map(\.revision.number) == [1])

        let error = await #expect(throws: LoreError.self) {
            try await repository.history(of: "missing.txt")
        }
        #expect(error?.code == .fileNotFound)
        let limitError = await #expect(throws: LoreError.self) {
            try await repository.history(of: "a.txt", limit: 0)
        }
        #expect(limitError?.code == .invalidArguments)
    }

    @Test func fileInfoReportsSizesAndChanges() async throws {
        let repository = try await repositoryWithTwoRevisions()
        try repository.write("changed\n", to: "a.txt")
        try repository.write("new\n", to: "c.txt")
        try FileManager.default.removeItem(atPath: "\(repository.path)/b.txt")

        let info = try await repository.fileInfo(of: ["a.txt", "b.txt", "c.txt", "missing.txt"])
        let byPath = Dictionary(uniqueKeysWithValues: info.map { ($0.path, $0) })
        #expect(Set(byPath.keys) == ["a.txt", "b.txt", "c.txt"])

        let a = try #require(byPath["a.txt"])
        #expect(a.kind == .file)
        #expect(a.size == 12)
        #expect(a.localSize == 8)
        #expect(a.isModified && !a.isAdded && !a.isDeleted && !a.isConflicted)
        #expect(byPath["b.txt"]?.isDeleted == true)
        #expect(byPath["c.txt"]?.isAdded == true)

        #expect(try await repository.fileInfo(of: ["a.txt"], revision: "main@1").first?.size == 4)
    }

    @Test func fileInfoReportsDirectories() async throws {
        let repository = try await makeOfflineRepository()
        try FileManager.default.createDirectory(atPath: "\(repository.path)/docs", withIntermediateDirectories: true)
        try repository.write("read me\n", to: "docs/README")
        try await repository.stage(["."])
        try await repository.commit(message: "Docs")
        #expect(try await repository.fileInfo(of: ["docs"]).map(\.kind) == [.directory])
    }

    @Test func diffReturnsUnifiedDiffs() async throws {
        let repository = try await repositoryWithTwoRevisions()
        let diffs = try await repository.diff(from: "main@1", to: "main@2")
        #expect(
            diffs == [
                FileDiff(
                    path: "a.txt",
                    action: .keep,
                    patch: """
                        --- a.txt@1
                        +++ a.txt@2
                        @@ -1 +1 @@
                        -one
                        +two, longer

                        """
                )
            ]
        )
        #expect(try await repository.diff(of: ["b.txt"], from: "main@1", to: "main@2").isEmpty)
    }

    @Test func diffComparesWithTheWorkingDirectory() async throws {
        let repository = try await repositoryWithTwoRevisions()
        try repository.write("three\n", to: "a.txt")
        let diff = try #require(try await repository.diff(of: ["a.txt"], from: "main@2").first)
        #expect(diff.patch.contains("+++ a.txt\n"))
        #expect(diff.patch.contains("+three\n"))
    }

    @Test func diffNamesAMissingSideDevNull() async throws {
        let repository = try await repositoryWithTwoRevisions()
        try FileManager.default.removeItem(atPath: "\(repository.path)/b.txt")
        try repository.write("new\n", to: "c.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "Three")

        let patches = Dictionary(
            uniqueKeysWithValues: try await repository.diff(from: "main@2", to: "main@3").map { ($0.path, $0) }
        )
        #expect(patches["b.txt"]?.action == .delete)
        #expect(patches["b.txt"]?.patch.hasPrefix("--- b.txt@2\n+++ /dev/null\n") == true)
        #expect(patches["c.txt"]?.action == .add)
        #expect(patches["c.txt"]?.patch.hasPrefix("--- /dev/null\n+++ c.txt\n") == true)
    }

    @Test func diffHonorsContextLinesAndWhitespaceOptions() async throws {
        let repository = try await makeOfflineRepository()
        let lines = (1 ... 9).map { "line \($0)\n" }
        try repository.write(lines.joined(), to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "One")
        var changed = lines
        changed[4] = "changed\n"
        changed[7] = "line 8 \n"
        try repository.write(changed.joined(), to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "Two")

        func patchLines(_ prefix: String, contextLines: Int = 0, ignoringTrailingWhitespace: Bool = false)
            async throws -> [Substring]
        {
            let diff = try #require(
                try await repository.diff(
                    from: "main@1",
                    to: "main@2",
                    contextLines: contextLines,
                    ignoringTrailingWhitespace: ignoringTrailingWhitespace
                ).first
            )
            return diff.patch.split(separator: "\n").filter { $0.hasPrefix(prefix) }
        }
        #expect(try await patchLines(" ").isEmpty)
        #expect(try await patchLines(" ", contextLines: 1) == [" line 4", " line 6", " line 7", " line 9"])
        #expect(try await patchLines("+") == ["+++ a.txt@2", "+changed", "+line 8 "])
        #expect(try await patchLines("+", ignoringTrailingWhitespace: true) == ["+++ a.txt@2", "+changed"])
    }

    @Test func unstageKeepsTheWorkingCopy() async throws {
        let repository = try await repositoryWithTwoRevisions()
        try repository.write("three\n", to: "a.txt")
        try repository.write("new\n", to: "c.txt")
        try await repository.stage(["."])
        #expect(try await repository.status().files.allSatisfy(\.isStaged))

        let unstaged = try await repository.unstage(["a.txt", "c.txt"])
        #expect(Set(unstaged.map(\.path)) == ["a.txt", "c.txt"])
        let status = try await repository.status()
        #expect(Set(status.files.map(\.path)) == ["a.txt", "c.txt"])
        #expect(status.files.allSatisfy { !$0.isStaged && $0.isDirty })
        #expect(try repository.read("a.txt") == "three\n")
    }

    @Test func resetDiscardsLocalChanges() async throws {
        let repository = try await repositoryWithTwoRevisions()
        try repository.write("three\n", to: "a.txt")
        try repository.write("new\n", to: "c.txt")

        let reset = try await repository.reset(["a.txt"])
        #expect(reset == [FileChange(path: "a.txt", action: .keep)])
        #expect(try repository.read("a.txt") == "two, longer\n")
        #expect(try await repository.status().files.map(\.path) == ["c.txt"])

        try await repository.reset(["."], deletingUntrackedFiles: true)
        #expect(!FileManager.default.fileExists(atPath: "\(repository.path)/c.txt"))
        #expect(try await repository.status().files.isEmpty)

        try await repository.reset(["a.txt"], to: "main@1")
        #expect(try repository.read("a.txt") == "one\n")
        #expect(try await repository.status().files.map(\.path) == ["a.txt"])
    }

    @Test func stageMoveStagesAMove() async throws {
        let repository = try await repositoryWithTwoRevisions()
        try FileManager.default.moveItem(atPath: "\(repository.path)/b.txt", toPath: "\(repository.path)/c.txt")
        try await repository.stageMove(from: "b.txt", to: "c.txt")
        let status = try await repository.status()
        #expect(status.files.map(\.path) == ["c.txt"])
        #expect(status.files.first?.previousPath == "b.txt")
        #expect(status.files.first?.action == .move)
        #expect(status.files.first?.isStaged == true)

        let revision = try await repository.commit(message: "Move")
        #expect(
            try await repository.changes(from: "main@2", to: .id(revision.id))
                == [FileChange(path: "c.txt", previousPath: "b.txt", action: .move, kind: .file)]
        )

        let untracked = await #expect(throws: LoreError.self) {
            try await repository.stageMove(from: "missing.txt", to: "d.txt")
        }
        #expect(untracked?.code == .nodeNotFound)
        let notOnDisk = await #expect(throws: LoreError.self) {
            try await repository.stageMove(from: "a.txt", to: "d.txt")
        }
        #expect(notOnDisk?.code == .internal)
    }
}

@Suite struct DirtyFileTests {
    /// Returns an offline repository with one revision that adds `a.txt` and `b.txt`.
    private func repository() async throws -> Repository {
        let repository = try await makeOfflineRepository()
        try repository.write("one\n", to: "a.txt")
        try repository.write("bee\n", to: "b.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "One")
        return repository
    }

    /// Returns the files that a status without a scan reports, by path.
    private func unscannedFiles(_ repository: Repository) async throws -> [String: FileStatus] {
        Dictionary(uniqueKeysWithValues: try await repository.status(scanning: false).files.map { ($0.path, $0) })
    }

    @Test func markDirtyReportsChangesWithoutAScan() async throws {
        let repository = try await repository()
        try repository.write("changed\n", to: "a.txt")
        try repository.write("new\n", to: "c.txt")
        try FileManager.default.removeItem(atPath: "\(repository.path)/b.txt")
        #expect(try await repository.status(scanning: false).files.isEmpty)

        try await repository.markDirty(["a.txt", "b.txt", "c.txt", "missing.txt", "/etc/hosts", ".lore/config.toml"])
        let files = try await unscannedFiles(repository)
        #expect(Set(files.keys) == ["a.txt", "b.txt", "c.txt"])
        #expect(files["a.txt"]?.action == .keep)
        #expect(files["b.txt"]?.action == .delete)
        #expect(files["c.txt"]?.action == .add)
        #expect(files.values.allSatisfy { $0.isDirty && !$0.isStaged })

        // Marking doesn't stage the content.
        let error = await #expect(throws: LoreError.self) {
            try await repository.commit(message: "Two")
        }
        #expect(error?.code == .nothingStaged)
        try await repository.stage(["a.txt"], scanning: false)
        let revision = try await repository.commit(message: "Two")
        #expect(try await repository.changes(in: .id(revision.id)).map(\.path) == ["a.txt"])
    }

    @Test func markDirtyRevertsAnAddAndSkipsIgnoredFiles() async throws {
        let repository = try await repository()
        try repository.write("new\n", to: "c.txt")
        try await repository.markDirty(["c.txt"])
        #expect(try await unscannedFiles(repository)["c.txt"]?.action == .add)

        // A file that's gone from the working directory and the revision
        // loses its mark.
        try FileManager.default.removeItem(atPath: "\(repository.path)/c.txt")
        try await repository.markDirty(["c.txt"])
        #expect(try await unscannedFiles(repository).isEmpty)

        try repository.write("*.log\n", to: ".loreignore")
        try repository.write("log\n", to: "debug.log")
        try await repository.markDirty(["debug.log"])
        #expect(try await unscannedFiles(repository).isEmpty)
    }

    @Test func markMovedRecordsAMoveThatTheNextCommitRecords() async throws {
        let repository = try await repository()
        try FileManager.default.moveItem(atPath: "\(repository.path)/b.txt", toPath: "\(repository.path)/c.txt")
        try await repository.markMoved(from: "b.txt", to: "c.txt")
        let files = try await unscannedFiles(repository)
        #expect(Array(files.keys) == ["c.txt"])
        #expect(files["c.txt"]?.previousPath == "b.txt")
        #expect(files["c.txt"]?.action == .move)
        #expect(files["c.txt"]?.isStaged == false)

        let revision = try await repository.commit(message: "Move")
        #expect(
            try await repository.changes(from: "main@1", to: .id(revision.id))
                == [FileChange(path: "c.txt", previousPath: "b.txt", action: .move, kind: .file)]
        )

        let error = await #expect(throws: LoreError.self) {
            try await repository.markMoved(from: "missing.txt", to: "d.txt")
        }
        #expect(error?.code == .nodeNotFound)
    }

    @Test func markCopiedReportsAnAddedFile() async throws {
        let repository = try await repository()
        try FileManager.default.copyItem(atPath: "\(repository.path)/b.txt", toPath: "\(repository.path)/c.txt")
        try await repository.markCopied(from: "b.txt", to: "c.txt")
        let files = try await unscannedFiles(repository)
        #expect(Array(files.keys) == ["c.txt"])
        #expect(files["c.txt"]?.action == .add)
        #expect(files["c.txt"]?.previousPath == nil)

        let error = await #expect(throws: LoreError.self) {
            try await repository.markCopied(from: "missing.txt", to: "d.txt")
        }
        #expect(error?.code == .nodeNotFound)
    }
}

@Suite struct AuditTests {
    /// Returns an offline repository with two revisions of `a.txt`:
    /// the first adds three lines, and the second changes the second line and adds a fourth.
    private func repository() async throws -> (Repository, [Revision]) {
        let repository = try await makeOfflineRepository()
        var revisions: [Revision] = []
        for text in ["one\ntwo\nthree\n", "one\nTWO\nthree\nfour\n"] {
            try repository.write(text, to: "a.txt")
            try await repository.stage(["a.txt"])
            revisions.append(try await repository.commit(message: "Revision \(revisions.count + 1)"))
        }
        return (repository, revisions)
    }

    @Test func auditAttributesLinesToRevisions() async throws {
        let (repository, revisions) = try await repository()
        let repositoryID = try await repository.state().repositoryID
        let attributions = try await repository.audit("a.txt")
        #expect(
            attributions == [
                LineAttribution(
                    lines: 1 ... 1,
                    revision: revisions[0].id,
                    repositoryID: repositoryID,
                    outcome: .attributed
                ),
                LineAttribution(
                    lines: 2 ... 2,
                    revision: revisions[1].id,
                    repositoryID: repositoryID,
                    outcome: .attributed
                ),
                LineAttribution(
                    lines: 3 ... 3,
                    revision: revisions[0].id,
                    repositoryID: repositoryID,
                    outcome: .attributed
                ),
                LineAttribution(
                    lines: 4 ... 4,
                    revision: revisions[1].id,
                    repositoryID: repositoryID,
                    outcome: .attributed
                ),
            ]
        )
        // Consecutive lines with the same revision form one range.
        #expect(
            try await repository.audit("a.txt", revision: "main@1") == [
                LineAttribution(
                    lines: 1 ... 3,
                    revision: revisions[0].id,
                    repositoryID: repositoryID,
                    outcome: .attributed
                )
            ]
        )
    }

    @Test func auditReportsUncommittedLines() async throws {
        let (repository, revisions) = try await repository()
        try repository.write("one\nTWO\nthree \nfour\nfive\n", to: "a.txt")

        let attributions = try await repository.audit("a.txt")
        #expect(attributions.map(\.lines) == [1 ... 1, 2 ... 2, 3 ... 3, 4 ... 4, 5 ... 5])
        #expect(attributions.map(\.outcome) == [.attributed, .attributed, .attributed, .attributed, .uncommitted])
        #expect(attributions[2].revision == revisions[0].id)
        #expect(attributions[4].revision == nil)

        let strict = try await repository.audit("a.txt", ignoringTrailingWhitespace: false)
        #expect(strict.map(\.outcome) == [.attributed, .attributed, .uncommitted, .attributed, .uncommitted])
    }

    @Test func auditHonorsTheRevisionLimit() async throws {
        let (repository, _) = try await repository()
        for text in ["ONE\nTWO\nthree\nfour\n", "ONE\nTWO\nTHREE\nfour\n"] {
            try repository.write(text, to: "a.txt")
            try await repository.stage(["a.txt"])
            try await repository.commit(message: "Another revision")
        }
        let limited = try await repository.audit("a.txt", revisionLimit: 1)
        #expect(limited.flatMap(\.lines) == [1, 2, 3, 4])
        let unresolved = limited.filter { $0.outcome == .revisionLimitReached }
        #expect(!unresolved.isEmpty)
        #expect(unresolved.allSatisfy { $0.revision == nil })

        let whole = try await repository.audit("a.txt", revisionLimit: nil)
        #expect(whole.flatMap(\.lines) == [1, 2, 3, 4])
        #expect(whole.allSatisfy { $0.outcome == .attributed })
        #expect(try await repository.audit("a.txt") == whole)

        let error = await #expect(throws: LoreError.self) {
            try await repository.audit("a.txt", revisionLimit: 0)
        }
        #expect(error?.code == .invalidArguments)
    }

    @Test func auditCanIgnoreChangesInWhitespace() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("a  b\nc\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let revision = try await repository.commit(message: "One")
        try repository.write("a b\nc\n", to: "a.txt")

        #expect(try await repository.audit("a.txt").map(\.outcome) == [.uncommitted, .attributed])
        let ignoring = try await repository.audit("a.txt", ignoringWhitespaceChanges: true)
        #expect(ignoring.map(\.lines) == [1 ... 2])
        #expect(ignoring.map(\.outcome) == [.attributed])
        #expect(ignoring.map(\.revision) == [revision.id])
    }

    @Test func auditReportsAnObliteratedEarlierVersion() async throws {
        let (repository, revisions) = try await repository()
        // The third revision changes only line 4,
        // which the audit can attribute without reading the first version.
        try repository.write("one\nTWO\nthree\nFOUR\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let third = try await repository.commit(message: "Revision 3")
        // Obliterate the first version of a.txt, whose content is "one\ntwo\nthree\n".
        // A file keeps its context across versions.
        let current = try #require(try await repository.storedContent(of: "a.txt"))
        let copy = scratchDirectory.appending(path: "audit-\(UUID().uuidString.prefix(8)).txt").path
        try await repository.writeContents(of: "a.txt", revision: "main@1", to: copy)
        let hash = try #require(try await repository.contentHashes(of: [copy]).first?.hash)
        let first = try #require(ContentAddress(hash: hash, context: current.address.context))
        #expect(try await repository.storedContent(at: first) != nil)
        try await repository.obliterate(contentAt: first)

        // Lore 0.11.0 reports the lines that need the removed version
        // as unavailable, not as obliterated.
        let repositoryID = try await repository.state().repositoryID
        #expect(
            try await repository.audit("a.txt") == [
                LineAttribution(
                    lines: 1 ... 3,
                    revision: nil,
                    repositoryID: repositoryID,
                    outcome: .contentUnavailable
                ),
                LineAttribution(lines: 4 ... 4, revision: third.id, repositoryID: repositoryID, outcome: .attributed),
            ]
        )
        // The version at the second revision is still there.
        try await repository.writeContents(
            of: "a.txt",
            revision: .id(revisions[1].id),
            to: copy,
            replacingExistingFile: true
        )
        #expect(try String(contentsOfFile: copy, encoding: .utf8) == "one\nTWO\nthree\nfour\n")
    }

    @Test func auditOfMissingAndEmptyFiles() async throws {
        let (repository, _) = try await repository()
        let error = await #expect(throws: LoreError.self) {
            try await repository.audit("missing.txt")
        }
        #expect(error?.code == .fileNotFound)

        try repository.write("", to: "empty.txt")
        try await repository.stage(["empty.txt"])
        try await repository.commit(message: "Empty")
        #expect(try await repository.audit("empty.txt").isEmpty)
    }
}
