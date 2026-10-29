import CLore
import Foundation
import Testing

@testable import Lore

/// Tests of stores of offline repositories and stores in memory.
@Suite struct ContentStoreTests {
    /// Creates an offline repository with `a.txt` in one revision.
    private func makeRepository() async throws -> (Repository, RepositoryID, Revision) {
        let repository = try await makeOfflineRepository()
        try repository.write("hello\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let revision = try await repository.commit(message: "First")
        return (repository, try await repository.state().repositoryID, revision)
    }

    /// Calls the library's flush function with a store's handle,
    /// bypassing the binding's check for a closed store.
    private func libraryFlush(_ repository: Repository, handleID: UInt64) async throws {
        _ = try await repository.perform(
            lore_storage_flush_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_flush_args_t>, _) in
                arguments.pointee.handle = lore_store_t(handle_id: handleID)
            },
            transform: { _ -> Never? in nil }
        )
    }

    private func hash(_ byte: UInt8) -> ContentStore.Hash {
        ContentStore.Hash(bytes: Array(repeating: byte, count: 32))!
    }

    private let zeroContext = [UInt8](repeating: 0, count: 16)

    @Test func opensAndClosesTheStoreOfARepository() async throws {
        let (created, id, _) = try await makeRepository()
        // A relative path resolves against the current directory of the process.
        let repository = Repository(path: relativePath(to: created.path), options: created.options)
        let store = try await repository.openStore()
        #expect(store.repository == repository)
        #expect(store.repositoryID == id)
        #expect(store.remote == nil)
        #expect(await !store.isClosed)
        try await store.close()
        #expect(await store.isClosed)
        try await store.close()

        let missing = await #expect(throws: LoreError.self) {
            try await Repository(path: temporaryPath("not-a-repository")).openStore()
        }
        #expect(missing?.code == .repositoryNotFound)
    }

    @Test func putsAndReadsContent() async throws {
        let (repository, id, _) = try await makeRepository()
        let store = try await repository.openStore()
        let context = [UInt8](repeating: 5, count: 16)

        let put = try await store.put(Data("hello\n".utf8), in: id, context: context)
        // The hash is the content hash that the repository stores for the same bytes.
        let stored = try #require(try await repository.storedContent(of: "a.txt"))
        #expect(put.address.hash == stored.address.hash)
        #expect(put.address.context == context)
        #expect(put.isStoredLocally)
        #expect(!put.isStoredOnServer)
        #expect(try await store.contents(at: put.address, in: id) == Data("hello\n".utf8))
        let metadata = try #require(try await store.storedContent(at: put.address, in: id))
        #expect(metadata.address == put.address)
        #expect(metadata.size == 6)
        #expect(metadata.payloadSize == 6)

        // Content of several fragments arrives in parts.
        let large = Data((0 ..< 3_000_000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 7) })
        let largePut = try await store.put(large, in: id)
        #expect(largePut.address.context == zeroContext)
        #expect(try await store.contents(at: largePut.address, in: id) == large)
        #expect(try await store.storedContent(at: largePut.address, in: id)?.size == large.count)

        // Compressed content has a payload smaller than its size.
        try String(repeating: "a", count: 65536).write(
            toFile: "\(repository.path)/compressible.txt",
            atomically: true,
            encoding: .utf8
        )
        try await repository.stage(["compressible.txt"])
        try await repository.commit(message: "Compressible")
        let compressed = try #require(try await repository.storedContent(of: "compressible.txt"))
        let compressedMetadata = try await store.storedContent(at: compressed.address, in: id)
        #expect(compressedMetadata == compressed)
        #expect(compressedMetadata?.size == 65536)
        #expect((compressedMetadata?.payloadSize ?? .max) < 65536)

        // Empty content isn't stored, and a zero hash reads as empty content.
        let empty = try await store.put(Data(), in: id, context: context)
        #expect(empty.address.hash == Array(repeating: 0, count: 32))
        #expect(empty.address.context == context)
        #expect(!empty.isStoredLocally)
        #expect(try await store.contents(at: empty.address, in: id).isEmpty)

        // Without a server, uploading writes only the local store.
        let uploading = try await store.put(Data("local\n".utf8), in: id, uploading: true)
        #expect(uploading.isStoredLocally)
        #expect(!uploading.isStoredOnServer)

        let absent = try #require(ContentAddress(hash: Array(repeating: 3, count: 32), context: context))
        let missing = await #expect(throws: LoreError.self) { try await store.contents(at: absent, in: id) }
        #expect(missing?.code == .addressNotFound)
        #expect(try await store.storedContent(at: absent, in: id) == nil)
        let badContext = await #expect(throws: LoreError.self) {
            try await store.put(Data("x".utf8), in: id, context: [1, 2, 3])
        }
        #expect(badContext?.code == .invalidArguments)
        try await store.close()
    }

    @Test func putsAndWritesFiles() async throws {
        let (repository, id, _) = try await makeRepository()
        let store = try await repository.openStore()

        // Relative paths resolve against the current directory of the process.
        let put = try await store.put(contentsOfFile: relativePath(to: "\(repository.path)/a.txt"), in: id)
        #expect(put.address.hash == (try await repository.storedContent(of: "a.txt"))?.address.hash)
        #expect(put.address.context == zeroContext)
        #expect(put.isStoredLocally)
        let context = [UInt8](repeating: 5, count: 16)
        let withContext = try await store.put(contentsOfFile: "\(repository.path)/a.txt", in: id, context: context)
        #expect(withContext.address.hash == put.address.hash)
        #expect(withContext.address.context == context)

        // An empty file isn't stored, and its address has a zero hash.
        let emptyFile = temporaryPath("empty")
        FileManager.default.createFile(atPath: emptyFile, contents: Data())
        let empty = try await store.put(contentsOfFile: emptyFile, in: id, context: context)
        #expect(empty.address.hash == Array(repeating: 0, count: 32))
        #expect(empty.address.context == context)
        #expect(!empty.isStoredLocally)

        let destination = temporaryPath("written")
        try "existing".write(toFile: destination, atomically: true, encoding: .utf8)
        try await store.writeContents(at: put.address, in: id, to: relativePath(to: destination))
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "hello\n")

        // The address of a file's content in the repository reads the file's content.
        let stored = try #require(try await repository.storedContent(of: "a.txt"))
        let copy = temporaryPath("stored")
        try await store.writeContents(at: stored.address, in: id, to: copy)
        #expect(try String(contentsOfFile: copy, encoding: .utf8) == "hello\n")

        let missingFile = await #expect(throws: LoreError.self) {
            try await store.put(contentsOfFile: "\(repository.path)/missing.txt", in: id)
        }
        #expect(missingFile?.code == .invalidArguments)
        let absent = try #require(ContentAddress(hash: Array(repeating: 3, count: 32), context: zeroContext))
        let missingContent = await #expect(throws: LoreError.self) {
            try await store.writeContents(at: absent, in: id, to: temporaryPath("absent"))
        }
        #expect(missingContent?.code == .addressNotFound)
        try await store.close()
    }

    @Test func copiesContentBetweenRepositories() async throws {
        let (repository, id, _) = try await makeRepository()
        let (_, otherID, _) = try await makeRepository()
        let store = try await repository.openStore()
        let source = try await store.put(Data("shared\n".utf8), in: id, context: Array(repeating: 5, count: 16))

        let copy = try await store.copy(source.address, from: id, to: otherID)
        #expect(copy == source.address)
        let retagged = try await store.copy(
            source.address,
            from: id,
            to: id,
            context: Array(repeating: 6, count: 16)
        )
        #expect(retagged.hash == source.address.hash)
        #expect(retagged.context == Array(repeating: 6, count: 16))

        // The copy stays when the source goes.
        try await store.obliterate(source.address, in: id)
        let gone = await #expect(throws: LoreError.self) { try await store.contents(at: source.address, in: id) }
        #expect(gone?.code == .addressNotFound)
        #expect(try await store.contents(at: copy, in: otherID) == Data("shared\n".utf8))

        let itself = await #expect(throws: LoreError.self) {
            try await store.copy(copy, from: otherID, to: otherID)
        }
        #expect(itself?.code == .invalidArguments)
        let absent = try #require(ContentAddress(hash: Array(repeating: 3, count: 32), context: zeroContext))
        let missing = await #expect(throws: LoreError.self) {
            try await store.copy(absent, from: id, to: otherID)
        }
        #expect(missing?.code == .addressNotFound)
        try await store.close()
    }

    @Test func readsFindContentByItsHash() async throws {
        let (repository, id, _) = try await makeRepository()
        let (_, otherID, _) = try await makeRepository()
        let store = try await repository.openStore()
        let context = [UInt8](repeating: 5, count: 16)
        let put = try await store.put(Data("found\n".utf8), in: id, context: context)

        // Lore 0.12.0 finds the hash under another partition and another context.
        let otherContext = try #require(ContentAddress(hash: put.address.hash, context: zeroContext))
        for (address, partition) in [(put.address, otherID), (otherContext, id)] {
            #expect(try await store.contents(at: address, in: partition) == Data("found\n".utf8))
            #expect(try await store.storedContent(at: address, in: partition)?.address == address)
            let file = temporaryPath("found")
            try await store.writeContents(at: address, in: partition, to: file)
            #expect(try String(contentsOfFile: file, encoding: .utf8) == "found\n")
        }

        // Obliterating the content in a partition ends that.
        let copy = try await store.copy(put.address, from: id, to: otherID)
        try await store.obliterate(copy, in: otherID)
        let gone = await #expect(throws: LoreError.self) { try await store.contents(at: copy, in: otherID) }
        #expect(gone?.code == .addressNotFound)
        #expect(try await store.contents(at: put.address, in: id) == Data("found\n".utf8))
        try await store.close()
    }

    @Test func flushesAndKeepsContentAfterClosing() async throws {
        let (repository, id, _) = try await makeRepository()
        let store = try await repository.openStore()
        let put = try await store.put(Data("kept\n".utf8), in: id)
        try await store.flush()
        try await store.close()

        let reopened = try await repository.openStore()
        #expect(try await reopened.contents(at: put.address, in: id) == Data("kept\n".utf8))
        try await reopened.close()

        let memory = try await ContentStore.openInMemory()
        try await memory.flush()
        try await memory.close()
    }

    @Test func obliteratesContentInAScratchRepository() async throws {
        let (repository, id, _) = try await makeRepository()
        let (_, otherID, _) = try await makeRepository()
        let address = try #require(try await repository.storedContent(of: "a.txt")).address
        let store = try await repository.openStore()
        let copy = try await store.copy(address, from: id, to: otherID)

        let obliteration = try await store.obliterate(address, in: id)
        #expect(obliteration.address == address)
        #expect(obliteration.isRemovedLocally)
        #expect(!obliteration.isRemovedFromServer)
        #expect(try await store.storedContent(at: address, in: id) == nil)
        // The repository's revision keeps the file without its content.
        let unreadable = await #expect(throws: LoreError.self) {
            try await repository.writeContents(of: "a.txt", to: temporaryPath("obliterated"))
        }
        #expect(unreadable?.code == .addressNotFound)
        // The content stays in the other partition.
        #expect(try await store.contents(at: copy, in: otherID) == Data("hello\n".utf8))

        // Obliterating content that's gone succeeds.
        #expect(try await store.obliterate(address, in: id).isRemovedLocally)
        try await store.close()
    }

    @Test func storesComparesAndSwapsValues() async throws {
        let (repository, id, _) = try await makeRepository()
        let store = try await repository.openStore()
        let key = hash(1)

        #expect(try await store.value(forKey: key, in: id) == nil)
        try await store.setValue(hash(2), forKey: key, in: id)
        #expect(try await store.value(forKey: key, in: id) == hash(2))
        // The kind is part of the key.
        #expect(try await store.value(forKey: key, ofType: .published, in: id) == nil)
        // The local store replaces the third byte of a key with its kind.
        var sameKey = key.bytes
        sameKey[2] = 0x5a
        #expect(try await store.value(forKey: try #require(ContentStore.Hash(bytes: sameKey)), in: id) == hash(2))

        let won = try await store.compareAndSwap(valueForKey: key, in: id, expecting: hash(2), replacingWith: hash(3))
        #expect(won == .swapped)
        #expect(try await store.value(forKey: key, in: id) == hash(3))
        let lost = try await store.compareAndSwap(valueForKey: key, in: id, expecting: hash(2), replacingWith: hash(4))
        #expect(lost == .mismatched(current: hash(3)))
        #expect(try await store.value(forKey: key, in: id) == hash(3))

        // `nil` expects a key without a value.
        let created = try await store.compareAndSwap(
            valueForKey: hash(5),
            in: id,
            expecting: nil,
            replacingWith: hash(6)
        )
        #expect(created == .swapped)
        let removed = try await store.compareAndSwap(
            valueForKey: hash(5),
            in: id,
            expecting: hash(6),
            replacingWith: nil
        )
        #expect(removed == .swapped)
        #expect(try await store.value(forKey: hash(5), in: id) == nil)
        let absent = try await store.compareAndSwap(
            valueForKey: hash(5),
            in: id,
            expecting: hash(6),
            replacingWith: nil
        )
        #expect(absent == .mismatched(current: nil))

        // The all-zero hash means no value, as `nil` does.
        let zeroCreated = try await store.compareAndSwap(
            valueForKey: hash(5),
            in: id,
            expecting: hash(0),
            replacingWith: hash(6)
        )
        #expect(zeroCreated == .swapped)
        #expect(try await store.value(forKey: hash(5), in: id) == hash(6))
        try await store.setValue(hash(0), forKey: hash(5), in: id)
        #expect(try await store.value(forKey: hash(5), in: id) == nil)

        // A create that finds a value loses and leaves the value.
        let taken = try await store.compareAndSwap(valueForKey: key, in: id, expecting: nil, replacingWith: hash(7))
        #expect(taken == .mismatched(current: hash(3)))
        #expect(try await store.value(forKey: key, in: id) == hash(3))

        // A swap of another kind changes only the value of that kind.
        let published = try await store.compareAndSwap(
            valueForKey: key,
            ofType: .published,
            in: id,
            expecting: nil,
            replacingWith: hash(8)
        )
        #expect(published == .swapped)
        #expect(try await store.value(forKey: key, ofType: .published, in: id) == hash(8))
        #expect(try await store.value(forKey: key, in: id) == hash(3))
        let again = try await store.compareAndSwap(
            valueForKey: key,
            ofType: .published,
            in: id,
            expecting: nil,
            replacingWith: hash(9)
        )
        #expect(again == .mismatched(current: hash(8)))

        try await store.setValue(nil, forKey: key, in: id)
        #expect(try await store.value(forKey: key, in: id) == nil)
        try await store.close()
    }

    @Test func listsTheKeysOfAKind() async throws {
        let (repository, id, revision) = try await makeRepository()
        let (_, otherID, _) = try await makeRepository()
        let store = try await repository.openStore()

        try await store.setValue(hash(2), forKey: hash(1), ofType: .published, in: id)
        try await store.setValue(hash(3), forKey: hash(1), ofType: .published, in: otherID)
        try await store.setValue(hash(4), forKey: hash(9), in: id)
        // A listed key has its kind in its third byte.
        var listedKey = hash(1).bytes
        listedKey[2] = UInt8(ContentStore.KeyType.published.rawValue)
        let listed = try await store.entries(ofType: .published, in: id)
        #expect(listed == [.init(key: try #require(ContentStore.Hash(bytes: listedKey)), value: hash(2))])
        #expect(try await store.value(forKey: listed[0].key, ofType: .published, in: id) == hash(2))
        #expect(Set(try await store.entries(ofType: .published, in: nil).map(\.value)) == [hash(2), hash(3)])
        // Lore 0.12.0 lists no untyped keys.
        #expect(try await store.entries(ofType: .untyped, in: id).isEmpty)
        try await store.setValue(nil, forKey: hash(1), ofType: .published, in: id)
        #expect(try await store.entries(ofType: .published, in: id).isEmpty)

        // The repository keeps the latest revision of its branch in the mutable store.
        let latest = try await store.entries(ofType: .branchLatest, in: id)
        #expect(latest.map(\.value) == [ContentStore.Hash(revision.id)])
        #expect(try await store.entries(ofType: .instance, in: id).count == 1)
        try await store.close()
    }

    @Test func publishesAndResolvesContent() async throws {
        let (repository, id, _) = try await makeRepository()
        let store = try await repository.openStore()
        let key = hash(7)
        let context = [UInt8](repeating: 5, count: 16)

        #expect(try await store.contents(publishedAs: key, in: id) == nil)
        let published = try await store.publish(Data("published\n".utf8), as: key, in: id, context: context)
        #expect(published.isStoredLocally)
        #expect(published.address.context == context)
        let resolved = try #require(try await store.contents(publishedAs: key, in: id, context: context))
        #expect(resolved.address == published.address)
        #expect(resolved.data == Data("published\n".utf8))
        // The key is a key of type `published` whose value is the content's hash.
        #expect(try await store.value(forKey: key, ofType: .published, in: id)?.bytes == published.address.hash)
        #expect(try await store.contents(at: published.address, in: id) == Data("published\n".utf8))

        let file = temporaryPath("resolved")
        #expect(
            try await store.writeContents(publishedAs: key, in: id, context: context, to: file) == published.address
        )
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "published\n")

        // Publishing again replaces the content that the key names.
        let fromFile = try await store.publish(
            contentsOfFile: "\(repository.path)/a.txt",
            as: key,
            in: id,
            context: context
        )
        #expect(fromFile.address.hash == (try await repository.storedContent(of: "a.txt"))?.address.hash)
        #expect(fromFile.address.context == context)
        let resolvedFile = try await store.contents(publishedAs: key, in: id, context: context)
        #expect(resolvedFile?.address == fromFile.address)
        #expect(resolvedFile?.data == Data("hello\n".utf8))

        // A path that can't be read doesn't remove the key.
        let missingPath = await #expect(throws: LoreError.self) {
            try await store.publish(contentsOfFile: "\(repository.path)/missing.txt", as: key, in: id)
        }
        #expect(missingPath?.code == .invalidArguments)
        #expect(try await store.contents(publishedAs: key, in: id)?.data == Data("hello\n".utf8))

        // An empty file removes the key.
        let emptyFile = temporaryPath("empty")
        FileManager.default.createFile(atPath: emptyFile, contents: Data())
        try await store.publish(contentsOfFile: emptyFile, as: key, in: id)
        #expect(try await store.value(forKey: key, ofType: .published, in: id) == nil)
        try await store.publish(Data("published\n".utf8), as: key, in: id)

        // Empty content removes the key, and a read of a missing key leaves the file.
        let removal = try await store.publish(Data(), as: key, in: id)
        #expect(removal.address.hash == Array(repeating: 0, count: 32))
        #expect(try await store.contents(publishedAs: key, in: id) == nil)
        #expect(try await store.value(forKey: key, ofType: .published, in: id) == nil)
        #expect(try await store.writeContents(publishedAs: key, in: id, to: file) == nil)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "published\n")

        // A key that names content the store doesn't hold reads as no content.
        try await store.setValue(hash(5), forKey: key, ofType: .published, in: id)
        #expect(try await store.contents(publishedAs: key, in: id) == nil)
        #expect(try await store.writeContents(publishedAs: key, in: id, to: file) == nil)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "published\n")

        let zeroKey = await #expect(throws: LoreError.self) {
            try await store.publish(Data("x".utf8), as: hash(0), in: id)
        }
        #expect(zeroKey?.code == .invalidArguments)
        try await store.close()
    }

    @Test func loadsARevisionTreeThatCommitsContentFromTheStore() async throws {
        let (repository, id, first) = try await makeRepository()
        let store = try await repository.openStore()
        let content = Data("from the store\n".utf8)
        let put = try await store.put(content, in: id)
        let tree = try await store.loadRevisionTree()
        #expect(try await tree.info().revision == first.id)
        try await tree.add([.file(named: "b.txt", in: .node(.root), address: put.address, size: content.count)])

        // The tree stays usable after the store closes.
        try await store.close()
        let revision = try await tree.commit(message: "Add b.txt")
        try await tree.close()
        #expect(revision.parents == [first.id])

        try await repository.sync(to: .id(revision.id))
        #expect(try repository.read("b.txt") == "from the store\n")
        #expect(try repository.read("a.txt") == "hello\n")

        let closed = await #expect(throws: LoreError.self) { try await store.loadRevisionTree() }
        #expect(closed == ContentStore.closedError)
    }

    @Test func loadsAnEmptyRevisionTreeFromTheStore() async throws {
        let repository = try await makeOfflineRepository()
        let branchID = try #require(try await repository.status().branchID)
        let store = try await repository.openStore()
        let tree = try await store.loadEmptyRevisionTree()
        try await tree.add([.directory(named: "docs", in: .node(.root))])
        try await tree.setMetadata(["branch": .context(branchID.bytes)])
        let revision = try await tree.commit(message: "Initial")
        #expect(revision.number == 1)
        try await tree.close()
        try await store.close()

        let memory = try await ContentStore.openInMemory()
        #expect(memory.repository == nil)
        for error in [
            await #expect(throws: LoreError.self) { try await memory.loadRevisionTree() },
            await #expect(throws: LoreError.self) { try await memory.loadEmptyRevisionTree() },
        ] {
            #expect(error?.code == .invalidArguments)
        }
        try await memory.close()
    }

    @Test func storesContentInMemory() async throws {
        _ = isolatedHome
        let id = try #require(RepositoryID(bytes: Array(repeating: 1, count: 16)))
        let store = try await ContentStore.openInMemory()
        let put = try await store.put(Data("memory\n".utf8), in: id)
        #expect(put.isStoredLocally)
        #expect(try await store.contents(at: put.address, in: id) == Data("memory\n".utf8))
        try await store.publish(Data("memory\n".utf8), as: hash(1), in: id)
        let values = try await store.entries(ofType: .published, in: nil).map(\.value.bytes)
        #expect(values == [put.address.hash])
        try await store.close()

        // A new store in memory is empty.
        let other = try await ContentStore.openInMemory()
        #expect(try await other.entries(ofType: .published, in: nil).isEmpty)
        let missing = await #expect(throws: LoreError.self) { try await other.contents(at: put.address, in: id) }
        #expect(missing?.code == .addressNotFound)
        try await other.close()
    }

    @Test func uploadNeedsAServer() async throws {
        let (repository, id, _) = try await makeRepository()
        let store = try await repository.openStore()
        let put = try await store.put(Data("x".utf8), in: id)
        let error = await #expect(throws: LoreError.self) { try await store.upload(put.address, in: id) }
        #expect(error?.code == .invalidArguments)
        try await store.close()
    }

    @Test func acceptsConcurrentCalls() async throws {
        let (repository, id, _) = try await makeRepository()
        let store = try await repository.openStore()
        let addresses = try await withThrowingTaskGroup(of: ContentAddress.self) { group in
            for index in 0 ..< 20 {
                group.addTask { try await store.put(Data("item \(index)\n".utf8), in: id).address }
            }
            return try await group.reduce(into: Set()) { $0.insert($1) }
        }
        #expect(addresses.count == 20)
        try await store.close()
    }

    @Test func closeWaitsForRunningCalls() async throws {
        let (repository, id, _) = try await makeRepository()
        // Without the wait, a call that started before the close
        // can pass the released handle to the library,
        // which reports it with a message of its own.
        for attempt in 0 ..< 20 {
            let store = try await repository.openStore()
            let outcomes = try await withThrowingTaskGroup(of: LoreError?.self) { group in
                for index in 0 ..< 10 {
                    group.addTask {
                        do {
                            try await store.put(Data("attempt \(attempt) item \(index)\n".utf8), in: id)
                            return nil
                        } catch {
                            return error as? LoreError ?? LoreError(code: .internal, message: "\(error)")
                        }
                    }
                }
                group.addTask {
                    try await store.close()
                    return nil
                }
                return try await group.reduce(into: [LoreError?]()) { $0.append($1) }
            }
            #expect(outcomes.allSatisfy { $0 == nil || $0 == ContentStore.closedError })
        }
    }

    /// Checks that every method of a closed store throws without calling the library,
    /// which would report the released handle with a message of its own.
    private func expectEveryMethodThrows(_ store: ContentStore, in id: RepositoryID) async throws {
        let address = try #require(ContentAddress(hash: Array(repeating: 1, count: 32), context: zeroContext))
        let path = temporaryPath("closed")
        let calls: [@Sendable () async throws -> Void] = [
            { try await store.put(Data("x".utf8), in: id) },
            { try await store.put(contentsOfFile: path, in: id) },
            { _ = try await store.contents(at: address, in: id) },
            { try await store.writeContents(at: address, in: id, to: path) },
            { _ = try await store.storedContent(at: address, in: id) },
            { try await store.copy(address, from: id, to: id, context: Array(repeating: 1, count: 16)) },
            { try await store.flush() },
            { try await store.obliterate(address, in: id) },
            { try await store.upload(address, in: id) },
            { try await store.publish(Data("x".utf8), as: self.hash(1), in: id) },
            { try await store.publish(contentsOfFile: path, as: self.hash(1), in: id) },
            { _ = try await store.contents(publishedAs: self.hash(1), in: id) },
            { try await store.writeContents(publishedAs: self.hash(1), in: id, to: path) },
            { _ = try await store.value(forKey: self.hash(1), in: id) },
            { try await store.setValue(self.hash(2), forKey: self.hash(1), in: id) },
            {
                _ = try await store.compareAndSwap(
                    valueForKey: self.hash(1),
                    in: id,
                    expecting: nil,
                    replacingWith: self.hash(2)
                )
            },
            { _ = try await store.entries(ofType: .published, in: id) },
            { _ = try await store.loadRevisionTree() },
            { _ = try await store.loadEmptyRevisionTree() },
        ]
        for call in calls {
            let error = await #expect(throws: LoreError.self) { try await call() }
            #expect(error == ContentStore.closedError)
        }
        // Closing again does nothing.
        try await store.close()
    }

    @Test func closingReleasesTheStoreOnce() async throws {
        let (repository, id, _) = try await makeRepository()
        let releases = ReleaseLog()
        var store: ContentStore? = try await repository.openStore(connectingTo: nil, onRelease: releases.record)
        let handleID = try #require(await store?.libraryHandleID)
        try await libraryFlush(repository, handleID: handleID)

        try await store?.close()
        #expect(await store?.isClosed == true)
        #expect(await store?.libraryHandleID == nil)
        #expect(releases.errors == [nil])
        // The library no longer knows the handle.
        let released = await #expect(throws: LoreError.self) {
            try await libraryFlush(repository, handleID: handleID)
        }
        #expect(released?.code == .invalidArguments)
        #expect(released?.message.contains("unknown or has been closed") == true)

        // Closing again doesn't call the library.
        try await store?.close()
        #expect(releases.errors == [nil])
        try await expectEveryMethodThrows(try #require(store), in: id)

        // Releasing the closed store doesn't close it again.
        let weakStore = WeakReference(store)
        store = nil
        #expect(weakStore.value == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(releases.errors == [nil])
    }

    @Test func releasingAnOpenStoreClosesIt() async throws {
        let (repository, id, _) = try await makeRepository()
        let releases = ReleaseLog()
        var store: ContentStore? = try await repository.openStore(connectingTo: nil, onRelease: releases.record)
        let handleID = try #require(await store?.libraryHandleID)
        let put = try #require(try await store?.put(Data("released\n".utf8), in: id))
        #expect(releases.errors.isEmpty)

        let weakStore = WeakReference(store)
        store = nil
        #expect(weakStore.value == nil)
        try await withTimeLimit {
            while releases.errors.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(releases.errors == [nil])
        let released = await #expect(throws: LoreError.self) {
            try await libraryFlush(repository, handleID: handleID)
        }
        #expect(released?.code == .invalidArguments)
        try await Task.sleep(for: .milliseconds(100))
        #expect(releases.errors == [nil])

        // The content stays, and the store opens again.
        let reopened = try await repository.openStore()
        #expect(try await reopened.contents(at: put.address, in: id) == Data("released\n".utf8))
        try await reopened.close()
    }
}

/// Tests of the library values that the binding writes for stores.
@Suite struct ContentStoreValueTests {
    @Test func hashesConvert() throws {
        let bytes = (0 ..< 32).map { UInt8($0) }
        let hash = try #require(ContentStore.Hash(bytes: bytes))
        #expect(hash.description == hexadecimal(bytes))
        #expect(ContentStore.Hash(hash.description) == hash)
        #expect(ContentStore.Hash(bytes: [1]) == nil)
        #expect(ContentStore.Hash(hash.libraryValue) == hash)
        #expect(ContentStore.Hash(lore_hash_t()) == nil)
        let revision = try #require(RevisionID(bytes: bytes))
        #expect(ContentStore.Hash(revision).bytes == bytes)
    }

    @Test func argumentsAreZeroedApartFromTheFieldsThatTheBindingSets() throws {
        // The header requires every byte of a structure to be zero,
        // padding included, unless the binding sets it.
        let arena = Arena()
        let item = arena.allocate(lore_storage_put_item_t.self)
        item.pointee.data = arena.bytes(Data("x".utf8))
        item.pointee.remote_write = 1
        let bytes = Array(UnsafeRawBufferPointer(start: item, count: MemoryLayout<lore_storage_put_item_t>.size))
        let remoteWrite = MemoryLayout<lore_storage_put_item_t>.offset(of: \.remote_write)!
        let chunk = MemoryLayout<lore_storage_put_item_t>.offset(of: \.fixed_size_chunk)!
        // The padding between `local_cache` and `fixed_size_chunk` stays zero.
        #expect(bytes[(remoteWrite + 1) ..< chunk].allSatisfy { $0 == 0 })
        #expect(arena.bytes(Data()).ptr == nil)
        withExtendedLifetime(arena) {}
    }
}

/// Tests of stores against a local server.
@Suite(.integration) struct ContentStoreIntegrationTests {
    /// Creates a repository on the server with one pushed revision.
    private func makePublishedRepository() async throws -> (Repository, RepositoryID, String) {
        let path = temporaryRepositoryPath("store")
        let url = "\(serverURL)/\(URL(filePath: path).lastPathComponent)"
        let repository = try await Repository.create(
            at: path,
            name: url,
            options: Repository.Options(identity: "alice@example.com")
        )
        try repository.write("hello\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "First")
        try await repository.push()
        return (repository, try await repository.state().repositoryID, url)
    }

    /// Returns the entry for an address on the server.
    private func serverEntry(for address: ContentAddress, in repository: Repository) async throws -> StoreEntry? {
        try await repository.storeEntries(for: address, checkingServer: true).first { $0.isOnServer }
    }

    @Test func uploadsContentToTheServer() async throws {
        let (repository, id, url) = try await makePublishedRepository()
        let store = try await repository.openStore(connectingTo: url)
        #expect(store.remote == url)

        let local = try await store.put(Data("uploaded later\n".utf8), in: id)
        #expect(local.isStoredLocally)
        #expect(!local.isStoredOnServer)
        #expect(try await serverEntry(for: local.address, in: repository)?.match == .notFound)
        #expect(try await store.upload(local.address, in: id))
        #expect(try await serverEntry(for: local.address, in: repository)?.match == .address)
        // The local store records that the server has the content.
        #expect(try await !store.upload(local.address, in: id))

        let absent = try #require(ContentAddress(hash: Array(repeating: 4, count: 32), context: local.address.context))
        let missing = await #expect(throws: LoreError.self) { try await store.upload(absent, in: id) }
        #expect(missing?.code == .addressNotFound)

        // Content written with `uploading` has its bytes only on the server.
        let uploaded = try await store.put(Data("uploaded at once\n".utf8), in: id, uploading: true)
        #expect(uploaded.isStoredOnServer)
        #expect(!uploaded.isStoredLocally)
        #expect(try await store.contents(at: uploaded.address, in: id) == Data("uploaded at once\n".utf8))
        let key = try #require(ContentStore.Hash(bytes: Array(repeating: 9, count: 32)))
        let published = try await store.publish(Data("published\n".utf8), as: key, in: id, uploading: true)
        #expect(published.isStoredOnServer)
        #expect(!published.isStoredLocally)

        // The file variants do the same.
        let file = temporaryPath("upload")
        try "uploaded file\n".write(toFile: file, atomically: true, encoding: .utf8)
        let context = [UInt8](repeating: 5, count: 16)
        let uploadedFile = try await store.put(contentsOfFile: file, in: id, context: context, uploading: true)
        #expect(uploadedFile.isStoredOnServer)
        #expect(!uploadedFile.isStoredLocally)
        #expect(uploadedFile.address.context == context)
        let fileKey = try #require(ContentStore.Hash(bytes: Array(repeating: 8, count: 32)))
        try "published file\n".write(toFile: file, atomically: true, encoding: .utf8)
        let publishedFile = try await store.publish(
            contentsOfFile: file,
            as: fileKey,
            in: id,
            context: context,
            uploading: true
        )
        #expect(publishedFile.isStoredOnServer)
        #expect(!publishedFile.isStoredLocally)
        try await store.close()

        // Another store reads them from the server.
        let memory = try await ContentStore.openInMemory(connectingTo: url, options: repository.options)
        #expect(try await memory.contents(at: uploaded.address, in: id) == Data("uploaded at once\n".utf8))
        #expect(try await memory.contents(at: local.address, in: id) == Data("uploaded later\n".utf8))
        #expect(try await memory.contents(at: uploadedFile.address, in: id) == Data("uploaded file\n".utf8))
        #expect(try await memory.contents(publishedAs: key, in: id)?.data == Data("published\n".utf8))
        let resolvedFile = try await memory.contents(publishedAs: fileKey, in: id, context: context)
        #expect(resolvedFile?.data == Data("published file\n".utf8))
        // The mutable store methods read only the local store.
        #expect(try await memory.value(forKey: key, ofType: .published, in: id) == nil)
        try await memory.close()

        // An offline store doesn't connect.
        let offline = Repository(
            path: repository.path,
            options: Repository.Options(identity: "alice@example.com", isOffline: true)
        )
        let offlineStore = try await offline.openStore(connectingTo: url)
        let put = try await offlineStore.put(Data("offline\n".utf8), in: id, uploading: true)
        #expect(put.isStoredLocally)
        #expect(!put.isStoredOnServer)
        let error = await #expect(throws: LoreError.self) { try await offlineStore.upload(put.address, in: id) }
        #expect(error?.code == .invalidArguments)
        try await offlineStore.close()
    }

    @Test func obliteratesContentOnTheServer() async throws {
        let (repository, id, url) = try await makePublishedRepository()
        let store = try await repository.openStore(connectingTo: url)
        let put = try await store.put(Data("obliterated\n".utf8), in: id, uploading: true)
        #expect(try await serverEntry(for: put.address, in: repository)?.match == .address)

        let obliteration = try await store.obliterate(put.address, in: id)
        #expect(obliteration.isRemovedLocally)
        #expect(obliteration.isRemovedFromServer)
        #expect(try await serverEntry(for: put.address, in: repository)?.match == .notFound)
        let gone = await #expect(throws: LoreError.self) { try await store.contents(at: put.address, in: id) }
        #expect(gone?.code == .addressNotFound)
        try await store.close()
    }
}
