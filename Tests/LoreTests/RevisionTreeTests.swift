import CLore
import Foundation
import Testing

@testable import Lore

/// Tests of revision trees on offline repositories.
@Suite struct RevisionTreeTests {
    /// Creates an offline repository with `a.txt` and `dir/b.txt` in one revision.
    private func makeRepository() async throws -> (Repository, Revision) {
        let repository = try await makeOfflineRepository()
        try repository.write("hello\n", to: "a.txt")
        try FileManager.default.createDirectory(atPath: "\(repository.path)/dir", withIntermediateDirectories: true)
        try repository.write("nested\n", to: "dir/b.txt")
        try await repository.stage(["."])
        let revision = try await repository.commit(message: "First")
        return (repository, revision)
    }

    /// Calls the library's revision tree info function with a handle,
    /// bypassing the binding's check for a closed tree.
    private func libraryInfo(_ repository: Repository, handleID: UInt64) async throws {
        _ = try await repository.perform(
            lore_revision_tree_info_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_info_args_t>, _) in
                arguments.pointee.handle = lore_revision_tree_t(handle_id: handleID)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Commits a tree with the library's function directly,
    /// without the identity values that the binding sets,
    /// and returns the new revision's metadata.
    private func libraryCommit(_ tree: RevisionTree, as repository: Repository) async throws -> [String: MetadataValue]
    {
        let handleID = try #require(await tree.libraryHandleID)
        let events = try await repository.perform(
            lore_revision_tree_commit_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_commit_args_t>, _) in
                arguments.pointee.handle = lore_revision_tree_t(handle_id: handleID)
            },
            transform: CommitEvent.init
        )
        let committed = try #require(CommitEvent.revision(of: tree.repositoryID, in: events))
        return try await repository.revision(.id(committed.id)).metadata
    }

    @Test(arguments: ["test@example.com", nil])
    func libraryRecordsNoIdentityForATreeCommit(_ identity: String?) async throws {
        // Lore 0.12.0 records the identity only for operations on a working directory,
        // although the header says that a tree commit records it.
        // If this test fails, the library has started to record it,
        // and `RevisionTree.commit(message:)` no longer needs to.
        let (created, _) = try await makeRepository()
        let repository = Repository(
            path: created.path,
            options: Repository.Options(identity: identity, isOffline: true)
        )
        #expect(try await repository.configurationValue(forKey: .identity) == "test@example.com")
        let tree = try await repository.loadRevisionTree()
        try await tree.setMetadata(["message": .string("Without the binding's identity")])
        try await tree.add([.directory(named: "docs", in: .node(.root))])
        let metadata = try await libraryCommit(tree, as: repository)
        #expect(metadata["message"] == .string("Without the binding's identity"))
        #expect(metadata["created-by"] == nil)
        #expect(metadata["committed-by"] == nil)
        try await tree.close()
    }

    @Test func readsTheLoadedRevision() async throws {
        let (repository, revision) = try await makeRepository()
        let tree = try await repository.loadRevisionTree()
        defer { withExtendedLifetime(tree) {} }

        let info = try await tree.info()
        let repositoryID = try await repository.state().repositoryID
        #expect(tree.repositoryID == repositoryID)
        #expect(info.repositoryID == repositoryID)
        #expect(info.revision == revision.id)
        #expect(info.parents.isEmpty)
        #expect(info.creator == "test@example.com")
        #expect(info.date.map { abs($0.timeIntervalSince(revision.date!)) < 0.002 } == true)
        #expect(info.metadataCount == revision.metadata.count)

        let root = try await tree.resolve("")
        #expect(root.nodeID == .root)
        #expect(root.repositoryID == repositoryID)
        #expect(root.revision == revision.id)

        let children = try await tree.children()
        #expect(Set(children.map(\.name)) == ["a.txt", "dir"])
        #expect(children.allSatisfy { $0.parentID == .root && $0.stagedAction == .unchanged })
        #expect(children.allSatisfy { $0.repositoryID == repositoryID && $0.revision == revision.id })

        let a = try await tree.resolve("a.txt").nodeID
        let file = try await tree.node(a)
        #expect(file.name == "a.txt")
        #expect(file.kind == .file)
        #expect(file.size == 6)
        #expect(file.address == (try await repository.storedContent(of: "a.txt"))?.address)
        #expect(children.contains(file))
        #expect(try await tree.path(of: a) == "a.txt")
        #expect(try await tree.path(of: .root) == "")

        let dir = try #require(children.first { $0.name == "dir" })
        #expect(dir.kind == .directory)
        let nested = try await tree.children(of: dir.id)
        #expect(nested.map(\.name) == ["b.txt"])
        #expect(nested.first?.parentID == dir.id)
        #expect(try await tree.resolve("dir/b.txt").nodeID == nested.first?.id)
        #expect(try await tree.path(of: nested[0].id) == "dir/b.txt")

        let rootNode = try await tree.node(.root)
        #expect(rootNode.name == "")
        #expect(rootNode.kind == .directory)

        for error in [
            await #expect(throws: LoreError.self) { try await tree.resolve("missing.txt") },
            await #expect(throws: LoreError.self) { try await tree.children(of: a) },
            await #expect(throws: LoreError.self) { try await tree.node(.init(rawValue: 999)) },
            await #expect(throws: LoreError.self) { try await tree.path(of: .init(rawValue: 999)) },
        ] {
            #expect(error?.code == .invalidArguments)
        }

        let earlier = try await repository.loadRevisionTree(of: "main@1")
        #expect(try await earlier.info().revision == revision.id)
        try await earlier.close()
        let missing = await #expect(throws: LoreError.self) {
            try await repository.loadRevisionTree(of: "main@9")
        }
        #expect(missing?.code == .revisionNotFound)
        try await tree.close()
    }

    @Test func editsAndCommitsWithoutTheWorkingDirectory() async throws {
        let (repository, first) = try await makeRepository()
        let tree = try await repository.loadRevisionTree()
        let a = try await tree.node(tree.resolve("a.txt").nodeID)
        let b = try await tree.node(tree.resolve("dir/b.txt").nodeID)
        let dir = try await tree.resolve("dir").nodeID
        let hello = try #require(a.address)
        let nested = try #require(b.address)
        let zeroContext = [UInt8](repeating: 0, count: 16)

        // A new directory with a copy of a.txt,
        // whose zero context gives it an identity of its own.
        let added = try await tree.add([
            .directory(named: "docs", in: .node(.root)),
            .file(
                named: "copy.txt",
                in: .entry(0),
                address: try #require(ContentAddress(hash: hello.hash, context: zeroContext)),
                size: a.size
            ),
        ])
        #expect(added.count == 2)
        let copy = try await tree.node(added[1])
        #expect(copy.parentID == added[0])
        #expect(copy.stagedAction == .add)
        #expect(copy.address?.hash == hello.hash)
        #expect(copy.address?.context != hello.context)
        #expect(copy.address?.context != zeroContext)
        #expect(try await tree.path(of: added[1]) == "docs/copy.txt")
        let duplicate = await #expect(throws: LoreError.self) {
            try await tree.add([.directory(named: "DOCS", in: .node(.root))])
        }
        #expect(duplicate?.code == .invalidArguments)

        // a.txt gets the content of dir/b.txt and keeps its identity.
        try await tree.modify([
            .init(
                node: a.id,
                address: try #require(ContentAddress(hash: nested.hash, context: zeroContext)),
                size: b.size,
                mode: 0o644
            )
        ])
        let modified = try await tree.node(a.id)
        #expect(modified.stagedAction == .modify)
        #expect(modified.address == ContentAddress(hash: nested.hash, context: hello.context))
        #expect(modified.size == b.size)
        #expect(modified.mode == 0o644)
        let directory = await #expect(throws: LoreError.self) {
            try await tree.modify([.init(node: dir, address: nested, size: 1)])
        }
        #expect(directory?.code == .invalidArguments)
        let negative = await #expect(throws: LoreError.self) {
            try await tree.modify([.init(node: a.id, address: nested, size: -1)])
        }
        #expect(negative?.code == .invalidArguments)
        #expect(try await tree.node(a.id) == modified)

        // A nonzero context replaces the identity of the copy.
        let identity = [UInt8](repeating: 7, count: 16)
        try await tree.modify([
            .init(
                node: added[1],
                address: try #require(ContentAddress(hash: hello.hash, context: identity)),
                size: a.size
            )
        ])
        #expect(try await tree.node(added[1]).address?.context == identity)

        // dir/b.txt moves to the root as e.txt, then dir goes.
        try await tree.move([.init(node: b.id, to: .root, name: "e.txt")])
        let moved = try await tree.node(b.id)
        #expect(moved.stagedAction == .move)
        #expect(moved.parentID == .root)
        #expect(moved.address == nested)
        #expect(try await tree.path(of: b.id) == "e.txt")
        #expect(try await tree.delete([dir]) == 1)
        #expect(try await tree.node(dir).stagedAction == .delete)
        let root = await #expect(throws: LoreError.self) { try await tree.delete([.root]) }
        #expect(root?.code == .invalidArguments)

        try await tree.setMetadata(["ticket": .string("ART-42"), "scratch": .boolean(true)])
        #expect(try await tree.clearMetadata(keys: ["scratch", "missing"]) == ["scratch"])

        let revision = try await tree.commit(message: "Edit in memory")
        #expect(revision.number == 2)
        #expect(revision.parents == [first.id])
        #expect(revision.branchID == first.branchID)
        #expect(revision.message == "Edit in memory")
        #expect(revision.creator == "test@example.com")
        #expect(revision.metadata["committed-by"] == .string("test@example.com"))
        #expect(revision.metadata["ticket"] == .string("ART-42"))
        #expect(revision.metadata["scratch"] == nil)
        #expect(revision.date != nil)
        #expect(try await repository.revision(.id(revision.id)) == revision)

        let changes = try await repository.changes(in: .id(revision.id))
        #expect(
            Set(changes.map { "\($0.action) \($0.previousPath.map { "\($0) -> " } ?? "")\($0.path)" }) == [
                "keep a.txt", "add docs", "add docs/copy.txt", "move dir/b.txt -> e.txt", "delete dir",
            ]
        )

        // The tree now holds the new revision, with the same node identifiers.
        let info = try await tree.info()
        #expect(info.revision == revision.id)
        #expect(info.parents == [first.id])
        #expect(info.creator == "test@example.com")
        #expect(try await tree.node(b.id).stagedAction == .unchanged)
        #expect(try await tree.path(of: added[1]) == "docs/copy.txt")
        #expect(try await tree.metadata(forKeys: ["message", "ticket"]).isEmpty)
        // A commit without edits records a revision with the same files.
        let unchanged = try await tree.commit(message: "No edits")
        #expect(unchanged.parents == [revision.id])
        #expect(try await repository.changes(in: .id(unchanged.id)).isEmpty)
        try await tree.close()

        // The working directory stays at its revision until it syncs.
        #expect(try await repository.status().revision == first.id)
        try repository.write("changed\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let advanced = await #expect(throws: LoreError.self) {
            try await repository.commit(message: "From the working directory")
        }
        #expect(advanced?.code == .branchAdvanced)
        try await repository.unstage(["a.txt"])
        try await repository.sync(to: .id(unchanged.id), discardingLocalChanges: true)
        #expect(try repository.read("a.txt") == "nested\n")
        #expect(try repository.read("e.txt") == "nested\n")
        #expect(try repository.read("docs/copy.txt") == "hello\n")
        #expect(!FileManager.default.fileExists(atPath: "\(repository.path)/dir/b.txt"))
    }

    @Test func keepsMetadataUntilTheCommit() async throws {
        let (repository, first) = try await makeRepository()
        let tree = try await repository.loadRevisionTree()
        let address = try #require(try await repository.storedContent(of: "a.txt")).address

        // The tree starts with no metadata of its own.
        #expect(try await tree.metadata(forKey: "message") == nil)
        #expect(try await tree.metadata(forKey: "message", includingLoadedRevision: true) == .string("First"))

        let values: [String: MetadataValue] = [
            "message": .string("Typed values"),
            "count": .number(3),
            "approved": .boolean(true),
            "blob": .binary([0, 1, 2, 255]),
            "hash": .hash(address.hash),
            "context": .context(address.context),
            "address": .address(hash: address.hash, context: address.context),
        ]
        try await tree.setMetadata(values)
        #expect(try await tree.metadata(forKeys: Array(values.keys) + ["missing"]) == values)
        // A value that the tree has takes precedence over the loaded revision's.
        #expect(try await tree.metadata(forKey: "message", includingLoadedRevision: true) == .string("Typed values"))
        #expect(try await tree.clearMetadata(keys: ["count", "count", "missing"]) == ["count"])
        #expect(try await tree.metadata(forKey: "count") == nil)
        // Clearing doesn't reach the loaded revision's values.
        #expect(try await tree.clearMetadata(keys: ["timestamp"]).isEmpty)
        #expect(
            try await tree.metadata(forKey: "timestamp", includingLoadedRevision: true) == first.metadata["timestamp"]
        )

        let short = await #expect(throws: LoreError.self) {
            try await tree.setMetadata(["hash": .hash([1, 2, 3])])
        }
        #expect(short?.code == .invalidArguments)

        // A file added under the root, so the commit has a change.
        try await tree.add([.file(named: "same.txt", in: .node(.root), address: address, size: 6)])
        let revision = try await tree.commit()
        #expect(revision.message == "Typed values")
        for (key, value) in values where key != "count" {
            #expect(revision.metadata[key] == value)
        }
        #expect(revision.metadata["count"] == nil)
        // The commit records only the values that the tree set,
        // and adds the branch, the time, and the identity.
        #expect(
            Set(revision.metadata.keys)
                == Set(values.keys).subtracting(["count"]).union(["branch", "timestamp", "created-by", "committed-by"])
        )
        try await tree.close()
    }

    @Test func addingADeletedNodeRestoresIt() async throws {
        let (repository, _) = try await makeRepository()
        let tree = try await repository.loadRevisionTree()
        let a = try await tree.node(tree.resolve("a.txt").nodeID)
        let address = try #require(a.address)
        #expect(try await tree.delete([a.id]) == 1)
        #expect(try await tree.node(a.id).stagedAction == .delete)

        // A zero context keeps the deleted file's identity.
        let restored = try await tree.add([
            .file(
                named: "a.txt",
                in: .node(.root),
                address: try #require(ContentAddress(hash: address.hash, context: Array(repeating: 0, count: 16))),
                size: a.size
            )
        ])
        #expect(restored == [a.id])
        let node = try await tree.node(a.id)
        #expect(node.stagedAction != .delete)
        #expect(node.address == address)

        // A node that the tree added is removed at once, freeing its name.
        let added = try await tree.add([.directory(named: "scratch", in: .node(.root))])
        #expect(try await tree.delete(added) == 1)
        #expect(try await !tree.children().contains { $0.name == "scratch" })
        try await tree.add([.directory(named: "scratch", in: .node(.root))])
        try await tree.close()
    }

    @Test func reportsEachNewNodeAndChecksParents() async throws {
        let (repository, _) = try await makeRepository()
        let tree = try await repository.loadRevisionTree()
        let dir = try await tree.resolve("dir").nodeID
        let stored = try #require(try await repository.storedContent(of: "a.txt"))
        let address = try #require(ContentAddress(hash: stored.address.hash, context: Array(repeating: 0, count: 16)))
        func file(_ name: String, in parent: RevisionTree.NewNode.Parent) -> RevisionTree.NewNode {
            .file(named: name, in: parent, address: address, size: stored.size)
        }

        // The library adds the nodes of different directories concurrently.
        let ids = try await tree.add([
            .directory(named: "new", in: .node(.root)),
            file("x.txt", in: .node(dir)),
            file("y.txt", in: .entry(0)),
            file("z.txt", in: .node(.root)),
        ])
        let parents: [RevisionTree.NodeID] = [.root, dir, ids[0], .root]
        for (index, path) in ["new", "dir/x.txt", "new/y.txt", "z.txt"].enumerated() {
            #expect(try await tree.path(of: ids[index]) == path)
            #expect(try await tree.node(ids[index]).parentID == parents[index])
        }

        let root = try await tree.children()
        let nested = try await tree.children(of: dir)
        let rejected: [[RevisionTree.NewNode]] = [
            [.directory(named: "p", in: .node(.root)), file("q.txt", in: .entry(-1))],
            [.directory(named: "p", in: .node(.root)), file("q.txt", in: .entry(2))],
            // The library takes only an earlier node as a parent.
            [file("q.txt", in: .entry(1)), .directory(named: "p", in: .node(.root))],
            [.file(named: "q.txt", in: .node(.root), address: address, size: -1)],
        ]
        for nodes in rejected {
            let error = await #expect(throws: LoreError.self) { try await tree.add(nodes) }
            #expect(error?.code == .invalidArguments)
            #expect(try await tree.children() == root)
            #expect(try await tree.children(of: dir) == nested)
        }
        try await tree.close()
    }

    @Test func deleteCountsTheNodesOfSubtrees() async throws {
        let (repository, _) = try await makeRepository()
        let tree = try await repository.loadRevisionTree()
        let a = try await tree.resolve("a.txt").nodeID
        let dir = try await tree.resolve("dir").nodeID
        let b = try await tree.resolve("dir/b.txt").nodeID

        // A node inside a directory that the same call deletes.
        let nested = await #expect(throws: LoreError.self) { try await tree.delete([dir, b]) }
        #expect(nested?.code == .invalidArguments)
        #expect(try await tree.node(dir).stagedAction == .unchanged)
        #expect(try await tree.node(b).stagedAction == .unchanged)

        #expect(try await tree.delete([dir]) == 2)
        #expect(try await tree.node(b).stagedAction == .delete)
        try await tree.close()

        let other = try await repository.loadRevisionTree()
        #expect(try await other.delete([a, dir]) == 3)
        try await other.close()
    }

    @Test func movesInOneCallApplyInOrder() async throws {
        let (repository, _) = try await makeRepository()
        let tree = try await repository.loadRevisionTree()
        let a = try await tree.resolve("a.txt").nodeID
        let b = try await tree.resolve("dir/b.txt").nodeID

        let collision = await #expect(throws: LoreError.self) {
            try await tree.move([
                .init(node: a, to: .root, name: "same.txt"), .init(node: b, to: .root, name: "same.txt"),
            ])
        }
        #expect(collision?.code == .invalidArguments)
        #expect(try await tree.path(of: a) == "a.txt")

        // The second move takes the name that the first frees.
        try await tree.move([.init(node: a, to: .root, name: "c.txt"), .init(node: b, to: .root, name: "a.txt")])
        #expect(try await tree.path(of: a) == "c.txt")
        #expect(try await tree.path(of: b) == "a.txt")
        #expect(try await tree.node(a).stagedAction == .move)
        #expect(try await tree.node(b).stagedAction == .move)
        let revision = try await tree.commit(message: "Swap")
        try await tree.close()

        try await repository.sync(to: .id(revision.id))
        #expect(try repository.read("c.txt") == "hello\n")
        #expect(try repository.read("a.txt") == "nested\n")
    }

    @Test func commitRecordsTheIdentityUnlessItsSet() async throws {
        let (created, first) = try await makeRepository()
        // Without an identity in the options, the commit uses the configured one.
        let configured = Repository(path: created.path, options: Repository.Options(isOffline: true))
        let tree = try await configured.loadRevisionTree()
        try await tree.add([.directory(named: "one", in: .node(.root))])
        let second = try await tree.commit(message: "Configured")
        #expect(second.creator == "test@example.com")
        #expect(second.metadata["committed-by"] == .string("test@example.com"))
        try await tree.close()

        // The identity in the options takes precedence over the configured one.
        let bob = Repository(
            path: created.path,
            options: Repository.Options(identity: "bob@example.com", isOffline: true)
        )
        let other = try await bob.loadRevisionTree(of: .id(second.id))
        try await other.add([.directory(named: "two", in: .node(.root))])
        let third = try await other.commit(message: "Bob")
        #expect(third.creator == "bob@example.com")
        #expect(third.metadata["committed-by"] == .string("bob@example.com"))

        // Values that you set stay.
        try await other.setMetadata(["created-by": .string("carol@example.com"), "committed-by": .number(1)])
        try await other.add([.directory(named: "three", in: .node(.root))])
        let fourth = try await other.commit(message: "Carol")
        #expect(fourth.creator == "carol@example.com")
        #expect(fourth.metadata["committed-by"] == .number(1))

        // A value that you set for one key leaves the other key to the commit.
        try await other.setMetadata(["created-by": .string("dave@example.com")])
        let fifth = try await other.commit(message: "Dave")
        #expect(fifth.creator == "dave@example.com")
        #expect(fifth.metadata["committed-by"] == .string("bob@example.com"))
        try await other.setMetadata(["committed-by": .number(2)])
        let sixth = try await other.commit(message: "Two")
        #expect(sixth.creator == "bob@example.com")
        #expect(sixth.metadata["committed-by"] == .number(2))

        // Without edits, the identity is enough to commit a revision with the same files.
        let seventh = try await other.commit()
        #expect(seventh.parents == [sixth.id])
        #expect(seventh.message == nil)
        #expect(seventh.creator == "bob@example.com")
        #expect(try await created.changes(in: .id(seventh.id)).isEmpty)
        try await other.close()

        // An empty identity in the options means none, so the commit uses the configured one.
        let empty = Repository(path: created.path, options: Repository.Options(identity: "", isOffline: true))
        let last = try await empty.loadRevisionTree(of: .id(seventh.id))
        let eighth = try await last.commit(message: "Empty")
        #expect(eighth.creator == "test@example.com")
        #expect(eighth.metadata["committed-by"] == .string("test@example.com"))
        try await last.close()
        #expect(first.number == 1)
    }

    @Test func readsBothParentsOfAMerge() async throws {
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
        let merge = try #require(try await repository.mergeBranch(named: "feature", message: "Merge").revision)

        let tree = try await repository.loadRevisionTree(of: .id(merge.id))
        let info = try await tree.info()
        #expect(info.revision == merge.id)
        #expect(info.parents == [main.id, feature.id])
        try await tree.close()
    }

    @Test func commitWithoutAnIdentityNeedsSomethingToCommit() async throws {
        let repository = try await Repository.create(
            at: temporaryRepositoryPath(),
            name: "test",
            options: Repository.Options(isOffline: true)
        )
        #expect(try await repository.configurationValue(forKey: .identity) == nil)
        let branchID = try #require(try await repository.status().branchID)
        let tree = try await repository.loadEmptyRevisionTree()
        try await tree.add([.directory(named: "docs", in: .node(.root))])
        try await tree.setMetadata(["branch": .context(branchID.bytes)])
        let revision = try await tree.commit()
        #expect(revision.creator == nil)
        #expect(revision.metadata["committed-by"] == nil)

        let nothing = await #expect(throws: LoreError.self) { try await tree.commit() }
        #expect(nothing?.code == .internal)
        try await tree.close()
    }

    @Test func commitOfAClosedTreeThrowsBeforeItReadsTheIdentity() async throws {
        let (created, _) = try await makeRepository()
        let repository = Repository(path: created.path, options: Repository.Options(isOffline: true))
        let tree = try await repository.loadRevisionTree()
        try await tree.close()
        // Reading the configured identity would now fail.
        try FileManager.default.moveItem(atPath: repository.path, toPath: repository.path + "-moved")
        let missing = await #expect(throws: LoreError.self) {
            try await repository.configurationValue(forKey: .identity)
        }
        #expect(missing != nil)
        let error = await #expect(throws: LoreError.self) { try await tree.commit(message: "Closed") }
        #expect(error == RevisionTree.closedError)
    }

    @Test func closeWaitsForARunningCommit() async throws {
        let (repository, _) = try await makeRepository()
        // Without the tree's lock, the close can run between the commit's library calls,
        // which then pass the released handle to the library.
        for attempt in 0 ..< 20 {
            let tree = try await repository.loadRevisionTree(of: .latest())
            try await tree.add([.directory(named: "d\(attempt)", in: .node(.root))])
            async let outcome: LoreError? = {
                do {
                    try await tree.commit(message: "Attempt \(attempt)")
                    return nil
                } catch {
                    return error as? LoreError ?? LoreError(code: .internal, message: "\(error)")
                }
            }()
            async let closed: Void = tree.close()
            try await closed
            let error = await outcome
            #expect(error == nil || error == RevisionTree.closedError)
        }
    }

    @Test func committingAStaleTreeKeepsItsEdits() async throws {
        let (repository, first) = try await makeRepository()
        let stale = try await repository.loadRevisionTree()
        let current = try await repository.loadRevisionTree()
        let a = try await stale.resolve("a.txt").nodeID
        try await stale.move([.init(node: a, to: .root, name: "renamed.txt")])
        try await current.delete([current.resolve("a.txt").nodeID])
        let second = try await current.commit(message: "Delete a.txt")
        #expect(second.parents == [first.id])

        // The branch moved past the revision that the stale tree holds.
        let error = await #expect(throws: LoreError.self) {
            try await stale.commit(message: "Rename a.txt")
        }
        #expect(error?.code == .internal)
        #expect(try await stale.node(a).stagedAction == .move)
        #expect(try await stale.info().revision == first.id)
        #expect(try await stale.metadata(forKey: "message") == .string("Rename a.txt"))
        try await stale.close()
        try await current.close()
    }

    @Test func commitsAFirstRevisionFromAnEmptyTree() async throws {
        let repository = try await makeOfflineRepository()
        let status = try await repository.status()
        let branchID = try #require(status.branchID)
        #expect(status.revision == nil)

        let tree = try await repository.loadEmptyRevisionTree()
        let info = try await tree.info()
        #expect(info.revision == nil)
        #expect(info.metadataCount == 0)
        #expect(info.creator == nil)
        #expect(try await tree.children().isEmpty)
        try await tree.add([
            .directory(named: "docs", in: .node(.root)),
            .directory(named: "notes", in: .entry(0)),
        ])
        let missingBranch = await #expect(throws: LoreError.self) { try await tree.commit(message: "Initial") }
        #expect(missingBranch?.code == .invalidArguments)

        try await tree.setMetadata(["branch": .context(branchID.bytes)])
        let revision = try await tree.commit()
        #expect(revision.number == 1)
        #expect(revision.parents.isEmpty)
        #expect(revision.branchID == branchID)
        #expect(revision.message == "Initial")
        try await tree.close()

        try await repository.sync(to: .latest())
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: "\(repository.path)/docs/notes", isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func acceptsConcurrentCalls() async throws {
        let (repository, _) = try await makeRepository()
        let tree = try await repository.loadRevisionTree()
        let a = try await tree.node(tree.resolve("a.txt").nodeID)
        let address = try #require(a.address)
        let ids = try await withThrowingTaskGroup(of: RevisionTree.NodeID.self) { group in
            for index in 0 ..< 20 {
                group.addTask {
                    try await tree.add([.file(named: "f\(index).txt", in: .node(.root), address: address, size: a.size)]
                    )[0]
                }
            }
            return try await group.reduce(into: Set()) { $0.insert($1) }
        }
        #expect(ids.count == 20)
        #expect(try await tree.children().count == 22)
        try await tree.close()
    }

    /// Checks that every method of a closed tree throws without calling the library,
    /// which would report the released handle with a message of its own.
    private func expectEveryMethodThrows(_ tree: RevisionTree, address: ContentAddress) async throws {
        let node = RevisionTree.NodeID(rawValue: 1)
        let calls: [@Sendable () async throws -> Void] = [
            { _ = try await tree.info() },
            { _ = try await tree.resolve("a.txt") },
            { _ = try await tree.children() },
            { _ = try await tree.node(.root) },
            { _ = try await tree.path(of: .root) },
            { try await tree.add([.directory(named: "x", in: .node(.root))]) },
            { try await tree.delete([node]) },
            { try await tree.modify([.init(node: node, address: address, size: 6)]) },
            { try await tree.move([.init(node: node, to: .root, name: "y")]) },
            { _ = try await tree.metadata(forKeys: ["message"]) },
            { try await tree.setMetadata(["message": .string("x")]) },
            { try await tree.clearMetadata(keys: ["message"]) },
            { try await tree.commit(message: "x") },
        ]
        for call in calls {
            let error = await #expect(throws: LoreError.self) { try await call() }
            #expect(error == RevisionTree.closedError)
        }
        // Closing again does nothing.
        try await tree.close()
    }

    @Test func closingReleasesTheTreeOnce() async throws {
        let (repository, _) = try await makeRepository()
        let address = try #require(try await repository.storedContent(of: "a.txt")).address
        let releases = ReleaseLog()
        var tree: RevisionTree? = try await repository.loadRevisionTree(of: nil, onRelease: releases.record)
        let handleID = try #require(await tree?.libraryHandleID)
        try await libraryInfo(repository, handleID: handleID)
        #expect(await tree?.isClosed == false)

        try await tree?.close()
        #expect(await tree?.isClosed == true)
        #expect(await tree?.libraryHandleID == nil)
        #expect(releases.errors == [nil])
        // The library no longer knows the handle.
        let released = await #expect(throws: LoreError.self) {
            try await libraryInfo(repository, handleID: handleID)
        }
        #expect(released?.code == .invalidArguments)
        #expect(released?.message.contains("unknown or has been closed") == true)

        // Closing again doesn't call the library.
        try await tree?.close()
        #expect(releases.errors == [nil])
        try await expectEveryMethodThrows(try #require(tree), address: address)

        // Releasing the closed tree doesn't close it again.
        let weakTree = WeakReference(tree)
        tree = nil
        #expect(weakTree.value == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(releases.errors == [nil])
    }

    @Test func releasingAnOpenTreeClosesIt() async throws {
        let (repository, _) = try await makeRepository()
        let releases = ReleaseLog()
        var tree: RevisionTree? = try await repository.loadRevisionTree(of: nil, onRelease: releases.record)
        let handleID = try #require(await tree?.libraryHandleID)
        let a = try #require(try await tree?.resolve("a.txt").nodeID)
        try await tree?.delete([a])
        #expect(releases.errors.isEmpty)

        let weakTree = WeakReference(tree)
        tree = nil
        #expect(weakTree.value == nil)
        try await withTimeLimit {
            while releases.errors.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(releases.errors == [nil])
        let released = await #expect(throws: LoreError.self) {
            try await libraryInfo(repository, handleID: handleID)
        }
        #expect(released?.code == .invalidArguments)
        try await Task.sleep(for: .milliseconds(100))
        #expect(releases.errors == [nil])

        // The edit wasn't committed, and the store is free for a new tree.
        let reloaded = try await repository.loadRevisionTree()
        #expect(try await reloaded.node(a).stagedAction == .unchanged)
        try await reloaded.close()
    }
}

/// Tests of the library values that the binding writes for revision trees.
@Suite struct RevisionTreeValueTests {
    @Test(arguments: [
        (MetadataValue.string("text"), 16),
        (.number(.max), 8),
        (.boolean(true), 1),
        (.binary([1, 2, 3]), 16),
        (.hash(Array(repeating: 0xff, count: 32)), 32),
        (.context(Array(repeating: 0xff, count: 16)), 16),
        (.address(hash: Array(repeating: 0xff, count: 32), context: Array(repeating: 0xff, count: 16)), 48),
    ])
    func metadataValuesKeepTheirPaddingZero(_ value: MetadataValue, memberSize: Int) throws {
        // The header requires every byte of a structure to be zero,
        // padding included, unless the binding sets it.
        let arena = Arena()
        let entry = arena.allocate(lore_revision_tree_metadata_set_entry_t.self)
        let metadata = try #require((entry).pointer(to: \.value))
        value.write(to: metadata, in: arena)
        let bytes = Array(UnsafeRawBufferPointer(start: metadata, count: MemoryLayout<lore_metadata_t>.size))
        // The tag is 4 bytes, and the union starts at 8.
        #expect(bytes[4 ..< 8].allSatisfy { $0 == 0 })
        #expect(bytes[(8 + memberSize)...].allSatisfy { $0 == 0 })
        #expect(MetadataValue(metadata.pointee) == value)
        withExtendedLifetime(arena) {}
    }
}

/// Tests of revision trees against a local server.
@Suite(.integration) struct RevisionTreeIntegrationTests {
    @Test func publishesATreeCommitBySyncingAndPushing() async throws {
        let path = temporaryRepositoryPath("tree")
        let url = "\(serverURL)/\(URL(filePath: path).lastPathComponent)"
        let repository = try await Repository.create(
            at: path,
            name: url,
            options: Repository.Options(identity: "alice@example.com")
        )
        try repository.write("hello\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let first = try await repository.commit(message: "First")
        try await repository.push()

        let tree = try await repository.loadRevisionTree()
        try await tree.move([.init(node: tree.resolve("a.txt").nodeID, to: .root, name: "b.txt")])
        let revision = try await tree.commit(message: "Rename a.txt")
        try await tree.close()
        #expect(revision.parents == [first.id])
        #expect(revision.creator == "alice@example.com")

        // The commit is local, and a push sends the revision that the working directory holds.
        let status = try await repository.status()
        #expect(status.revision == first.id)
        #expect(status.isLocalAhead)
        #expect(try await repository.push().wasAlreadyPushed)

        try await repository.sync(to: .id(revision.id))
        let push = try await repository.push()
        #expect(push.revision == revision.id)

        let clone = try await Repository.clone(
            from: url,
            to: temporaryRepositoryPath("tree-clone"),
            options: Repository.Options(identity: "bob@example.com")
        )
        #expect(try await clone.revision().id == revision.id)
        #expect(try clone.read("b.txt") == "hello\n")
        #expect(!FileManager.default.fileExists(atPath: "\(clone.path)/a.txt"))
    }
}
