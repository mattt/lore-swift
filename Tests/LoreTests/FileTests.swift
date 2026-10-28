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
}
