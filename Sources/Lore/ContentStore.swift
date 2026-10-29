import CLore
import Foundation
import Synchronization

/// An open handle to a content-addressed store,
/// for reading and writing content without a working directory.
///
/// Open the store of a repository with ``Repository/openStore(connectingTo:)``,
/// or a new, empty store in memory with ``openInMemory(connectingTo:options:)``.
/// A repository's store is its local store in its `.lore` directory,
/// or the shared store that the repository uses.
///
/// A store has two parts:
///
/// - The immutable store holds content by its ``ContentAddress``:
///   the hash of the content and a context, such as the identity of a file.
///   Use ``put(_:in:context:uploading:)`` and ``contents(at:in:)``,
///   or ``put(contentsOfFile:in:context:uploading:)``
///   and ``writeContents(at:in:to:)`` for files.
/// - The mutable store maps 32-byte keys to 32-byte values, by ``KeyType``.
///   Use ``value(forKey:ofType:in:)``, ``setValue(_:forKey:ofType:in:)``,
///   ``compareAndSwap(valueForKey:ofType:in:expecting:replacingWith:)``,
///   and ``entries(ofType:in:)``.
///   These methods read and write only the local mutable store,
///   also in a store with a server.
///
/// Content is *published* when a key of type ``KeyType/published``
/// in the mutable store names its hash.
/// ``publish(_:as:in:context:uploading:)`` stores content and publishes it in one call,
/// and ``contents(publishedAs:in:context:)`` resolves a key and reads the content it names.
/// The library calls these the *resolved* variants of put and get.
///
/// The methods that read and write content and keys take a partition:
/// the ``RepositoryID`` of a repository,
/// such as the store's ``repositoryID``,
/// under which the store records content and keys.
/// ``copy(_:from:to:context:)`` takes a source and a target partition,
/// and ``entries(ofType:in:)`` takes `nil` to list every partition.
/// In Lore 0.11.0, a read in one partition also finds content
/// that the store records with the same hash under another partition or context,
/// unless you obliterated the content in the partition that you read.
///
/// A store opened with a server's URL
/// can also write content to the server and read it from there;
/// see ``upload(_:in:)``.
///
/// An open store holds library resources
/// and, for a repository's store,
/// the claim of the store,
/// which makes other processes that use the store wait,
/// until you call ``close()``.
/// After ``close()``, every other method throws ``LoreError``
/// with ``LoreError/Code/invalidArguments``
/// without calling the library,
/// and ``close()`` does nothing.
/// If you release the last reference to a store without closing it,
/// its deinitializer starts the library call that closes it
/// and returns without waiting for the call to end.
/// The library closes a store once:
/// a store that you closed doesn't close it again.
///
/// Calls on one store can run at the same time.
/// ``close()`` waits for the calls that have started to end
/// before it closes the store.
public actor ContentStore {
    /// The repository whose store this is,
    /// or `nil` for a store in memory.
    public nonisolated let repository: Repository?

    /// The identifier of the store's repository,
    /// which is the partition of the repository's content and keys,
    /// or `nil` for a store in memory.
    public nonisolated let repositoryID: RepositoryID?

    /// The URL of the server that the store connects to,
    /// or `nil` for a store without a server.
    public nonisolated let serverURL: String?

    /// The options that calls on the store use.
    public nonisolated let options: Repository.Options

    /// The library's identifier for the store,
    /// or `nil` once the store is closed.
    private var handleID: UInt64?

    /// Runs once, when the library ends the call that closes the store,
    /// with the error if the call failed.
    private let onRelease: (@Sendable (LoreError?) -> Void)?

    /// The number of calls that have started and not ended.
    private var activeCalls = 0

    /// The calls to ``close()`` that wait for the active calls to end.
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        repository: Repository?,
        repositoryID: RepositoryID?,
        serverURL: String?,
        options: Repository.Options,
        handleID: UInt64,
        onRelease: (@Sendable (LoreError?) -> Void)? = nil
    ) {
        self.repository = repository
        self.repositoryID = repositoryID
        self.serverURL = serverURL
        self.options = options
        self.handleID = handleID
        self.onRelease = onRelease
    }

    deinit {
        // `close()` clears the identifier before it calls the library,
        // so a closed store isn't closed again.
        // Every running call holds a reference to the store,
        // so none is running here.
        guard let handleID else {
            return
        }
        ContentStore.release(handleID, caller: caller, onRelease: onRelease)
    }

    /// A Boolean value that indicates whether the store is closed.
    public var isClosed: Bool {
        handleID == nil
    }

    /// The identifier of the library resource, for tests.
    var libraryHandleID: UInt64? {
        handleID
    }

    /// Releases the store's library resources.
    ///
    /// The method waits for the calls on the store that have started to end,
    /// and then closes the store.
    /// The library then writes the store's pending changes to disk
    /// without waiting for them,
    /// and releases the claim of a repository's store
    /// once those writes end
    /// and every revision tree loaded from the store is closed.
    /// Closing a store doesn't close the trees that you loaded from it.
    /// Closing a store again does nothing.
    ///
    /// - Throws: ``LoreError`` if the library can't close the store.
    ///   The store is closed either way.
    public func close() async throws {
        guard let handleID else {
            return
        }
        self.handleID = nil
        while activeCalls > 0 {
            await withCheckedContinuation { closeWaiters.append($0) }
        }
        let onRelease = onRelease
        let (_, error) = await ContentStore.call(
            lore_storage_close_async,
            caller: caller,
            handle: lore_store_t(handle_id: handleID),
            configure: { (arguments: UnsafeMutablePointer<lore_storage_close_args_t>, handle, _) in
                arguments.pointee.handle = handle
            },
            transform: { _ -> Never? in nil }
        )
        onRelease?(error)
        if let error {
            throw error
        }
    }

    /// Starts the library call that closes a store, without waiting for it to end.
    private nonisolated static func release(
        _ handleID: UInt64,
        caller: Repository,
        onRelease: (@Sendable (LoreError?) -> Void)?
    ) {
        let arena = Arena()
        let globals = caller.globals(in: arena)
        let arguments = arena.allocate(lore_storage_close_args_t.self)
        arguments.pointee.handle = lore_store_t(handle_id: handleID)
        detach(
            onEnd: { error in onRelease?(error) },
            start: { callback in
                withExtendedLifetime(arena) {
                    lore_storage_close_async(globals, arguments, callback)
                }
            }
        )
    }
}

// MARK: - Opening

extension Repository {
    /// Opens the repository's store,
    /// to read and write content and keys without the working directory.
    ///
    /// The store is the repository's local store,
    /// or the shared store that the repository uses.
    /// Call ``ContentStore/close()`` when you're done with it:
    /// until then, other processes that use the store wait.
    ///
    /// - Parameter serverURL: The URL of a server,
    ///   such as the repository's ``ConfigurationKey/remoteURL``,
    ///   for calls that read or write content on the server,
    ///   or `nil` for a store that uses only the local store.
    ///   The store connects when a call first needs the server,
    ///   as the repository's ``Options/identity``.
    ///   An offline repository's store doesn't connect.
    /// - Returns: The open store.
    /// - Throws: ``LoreError`` if the library can't open the store,
    ///   such as ``LoreError/Code/repositoryNotFound``
    ///   for a directory that isn't a repository.
    public func openStore(connectingTo serverURL: String? = nil) async throws -> ContentStore {
        try await openStore(connectingTo: serverURL, onRelease: nil)
    }

    /// Opens the repository's store,
    /// with an operation that runs when the library closes the store, for tests.
    func openStore(
        connectingTo serverURL: String?,
        onRelease: (@Sendable (LoreError?) -> Void)?
    ) async throws -> ContentStore {
        let repositoryID = try await state().repositoryID
        let directory = absolutePath
        let handleID = try await ContentStore.open(caller: self, serverURL: serverURL) { arguments, arena in
            arguments.pointee.repository_path = arena.string(directory)
        }
        return ContentStore(
            repository: self,
            repositoryID: repositoryID,
            serverURL: serverURL,
            options: options,
            handleID: handleID,
            onRelease: onRelease
        )
    }
}

extension ContentStore {
    /// Opens a new, empty store in memory.
    ///
    /// The store keeps its content and keys in memory
    /// until you close it.
    /// It doesn't belong to a repository,
    /// so you can't load revision trees from it.
    ///
    /// - Parameters:
    ///   - serverURL: The URL of a server
    ///     for calls that read or write content on the server,
    ///     or `nil` for a store without a server.
    ///     The store connects when a call first needs the server,
    ///     as the identity in `options`.
    ///   - options: The options that calls on the store use.
    /// - Returns: The open store.
    /// - Throws: ``LoreError`` if the library can't open the store.
    public static func openInMemory(
        connectingTo serverURL: String? = nil,
        options: Repository.Options = Repository.Options()
    ) async throws -> ContentStore {
        let caller = Repository(path: "", options: options)
        let handleID = try await open(caller: caller, serverURL: serverURL) { arguments, _ in
            arguments.pointee.in_memory = 1
        }
        return ContentStore(
            repository: nil,
            repositoryID: nil,
            serverURL: serverURL,
            options: options,
            handleID: handleID
        )
    }

    /// Opens a store and returns the library's identifier for it.
    fileprivate static func open(
        caller: Repository,
        serverURL: String?,
        configure: (UnsafeMutablePointer<lore_storage_open_args_t>, Arena) -> Void
    ) async throws -> UInt64 {
        let handles = try await caller.perform(
            lore_storage_open_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_open_args_t>, arena) in
                configure(arguments, arena)
                if let serverURL {
                    arguments.pointee.has_remote_config = 1
                    arguments.pointee.remote_config.remote_url = arena.string(serverURL)
                }
            },
            transform: { event -> UInt64? in
                guard event.pointee.tag == LORE_EVENT_STORAGE_OPENED.rawValue else {
                    return nil
                }
                return event.pointee.storage_opened.handle_id
            }
        )
        guard let handleID = handles.last else {
            throw LoreError.missingEvent("a store")
        }
        return handleID
    }
}

// MARK: - Values

extension ContentStore {
    /// A 256-bit hash: a key or a value in the mutable store.
    ///
    /// Its ``description`` is 64 lowercase hexadecimal digits.
    ///
    /// The library uses the all-zero hash to mean "no value":
    /// setting a key to it removes the key,
    /// and the store's methods report a key without a value as `nil`,
    /// never as the all-zero hash.
    public struct Hash: Sendable, Hashable {
        /// The 32 bytes of the hash.
        public let bytes: [UInt8]

        /// Creates a hash from its 32 bytes.
        ///
        /// Returns `nil` if `bytes` doesn't hold exactly 32 bytes.
        public init?(bytes: [UInt8]) {
            guard bytes.count == 32 else {
                return nil
            }
            self.bytes = bytes
        }

        /// Creates a hash from 64 hexadecimal digits.
        ///
        /// Returns `nil` if `description` isn't 64 hexadecimal digits.
        public init?(_ description: some StringProtocol) {
            guard let bytes = decodeHexadecimal(description) else {
                return nil
            }
            self.init(bytes: bytes)
        }

        /// The hash of a revision ID.
        public init(_ revisionID: RevisionID) {
            self.bytes = revisionID.bytes
        }

        /// Copies a library hash,
        /// returning `nil` for the all-zero hash
        /// that the library uses to mean "none".
        init?(_ hash: lore_hash_t) {
            let bytes = tupleBytes(hash.data)
            guard bytes.contains(where: { $0 != 0 }) else {
                return nil
            }
            self.bytes = bytes
        }

        /// A Boolean value that indicates whether every byte of the hash is zero,
        /// which the library uses to mean "no value".
        var isZero: Bool {
            !bytes.contains { $0 != 0 }
        }

        /// The library hash.
        var libraryValue: lore_hash_t {
            var hash = lore_hash_t()
            setTupleBytes(&hash.data, to: bytes)
            return hash
        }
    }

    /// The kind of value that a key in the mutable store refers to.
    ///
    /// The kind is part of the key:
    /// the same key of two kinds names two values.
    /// In Lore 0.11.0, the local store replaces the third byte of a key
    /// with the raw value of its kind,
    /// so keys that differ only in that byte name the same value.
    /// The library keeps a repository's branches, metadata, and instances
    /// in the mutable store under the kinds other than ``untyped`` and ``published``,
    /// so changing those values changes the repository.
    ///
    /// Corresponds to `lore_key_type_t`.
    public struct KeyType: RawRepresentable, Sendable, Hashable {
        /// The raw value of the kind.
        public var rawValue: UInt32

        /// Creates a kind from its raw value.
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// A key without a specific kind.
        public static let untyped = Self(rawValue: LORE_KEY_TYPE_UNTYPED.rawValue)
        /// A key for branch metadata.
        public static let branchMetadata = Self(rawValue: LORE_KEY_TYPE_BRANCH_METADATA.rawValue)
        /// A key for a branch identifier.
        public static let branchID = Self(rawValue: LORE_KEY_TYPE_BRANCH_ID.rawValue)
        /// A key for the latest revision of a branch.
        public static let branchLatest = Self(rawValue: LORE_KEY_TYPE_BRANCH_LATEST_POINTER.rawValue)
        /// A key for repository metadata.
        public static let repositoryMetadata = Self(rawValue: LORE_KEY_TYPE_REPOSITORY_METADATA.rawValue)
        /// A key for a repository identifier.
        public static let repositoryID = Self(rawValue: LORE_KEY_TYPE_REPOSITORY_ID.rawValue)
        /// A key for a repository instance.
        public static let instance = Self(rawValue: LORE_KEY_TYPE_INSTANCE.rawValue)
        /// A key whose value is the hash of published content.
        ///
        /// See ``ContentStore/publish(_:as:in:context:uploading:)``.
        public static let published = Self(rawValue: LORE_KEY_TYPE_RESOLVE.rawValue)
    }

    /// Where a store put content.
    public struct PutResult: Sendable, Hashable {
        /// The address of the content.
        ///
        /// Its hash is all zeros for empty content,
        /// which the store doesn't store.
        public var address: ContentAddress

        /// A Boolean value that indicates whether the local store holds the content.
        ///
        /// It's `false` for empty content that the put methods don't store.
        /// It's also `false` for content that a store with a server
        /// puts or publishes with `uploading`,
        /// with the data or the file variant of either method:
        /// Lore 0.11.0 writes the bytes only to the server,
        /// although the header says that a publish always writes the local store,
        /// and reads fetch the bytes from the server.
        public var isStoredLocally: Bool

        /// A Boolean value that indicates whether the server holds the content.
        ///
        /// A write to the server that fails
        /// doesn't fail a write to the local store that succeeds:
        /// check this value to confirm that the server has the content.
        public var isStoredOnServer: Bool
    }

    /// Published content that a store read.
    public struct PublishedContent: Sendable, Hashable {
        /// The address of the content that the key names.
        public var address: ContentAddress

        /// The content.
        public var data: Data
    }

    /// The outcome of a compare-and-swap of a value in the mutable store.
    public enum SwapResult: Sendable, Hashable {
        /// The key held the expected value and now holds the new value.
        case swapped

        /// The key held another value, which it still holds,
        /// or `nil` if it held no value.
        case mismatched(current: Hash?)
    }

    /// A key and its value in the mutable store.
    public struct Entry: Sendable, Hashable {
        /// The key.
        public var key: Hash

        /// The value.
        public var value: Hash
    }

    /// The sides of a store that an obliteration acted on.
    public struct ObliterateResult: Sendable, Hashable {
        /// The address of the content.
        public var address: ContentAddress

        /// A Boolean value that indicates whether the content was removed from the local store,
        /// or the local store didn't hold it.
        public var isRemovedLocally: Bool

        /// A Boolean value that indicates whether the content was removed from the server,
        /// or the server didn't hold it.
        ///
        /// It's `false` for a store without a server.
        public var isRemovedFromServer: Bool
    }
}

extension ContentStore.Hash: LosslessStringConvertible {
    public var description: String {
        hexadecimal(bytes)
    }
}

// MARK: - Content

extension ContentStore {
    /// Stores content.
    ///
    /// The method copies `data` into memory that the library reads during the call,
    /// so the content is in memory twice.
    /// For a file, use ``put(contentsOfFile:in:context:uploading:)``.
    ///
    /// - Parameters:
    ///   - data: The content.
    ///     Empty content isn't stored, and its address has a zero hash.
    ///   - partition: The repository to store the content for.
    ///   - context: The 16-byte context of the content's address,
    ///     such as the identity of a file,
    ///     or `nil` for a zero context.
    ///   - uploading: Whether to write the content to the store's server;
    ///     see ``PutResult/isStoredLocally``.
    ///     The store ignores it without a server or when the store is offline.
    /// - Returns: The address of the content, and where the store put it.
    /// - Throws: ``LoreError`` if the store can't store the content,
    ///   or with ``LoreError/Code/invalidArguments``
    ///   for a context that doesn't hold 16 bytes.
    @discardableResult
    public func put(
        _ data: Data,
        in partition: RepositoryID,
        context: [UInt8]? = nil,
        uploading: Bool = false
    ) async throws -> PutResult {
        let context = try ContentStore.context(context)
        return try await putItem(
            lore_storage_put_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_put_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_put_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.context = context
                item.pointee.data = arena.bytes(data)
                item.pointee.remote_write = UInt8(uploading)
                arguments.pointee.items = lore_storage_put_item_array_t(ptr: item, count: 1)
            }
        )
    }

    /// Stores the content of a file.
    ///
    /// The library reads the file itself,
    /// so you don't load the content into memory.
    ///
    /// - Parameters:
    ///   - path: The path of the file,
    ///     relative to the current directory of the process unless it's absolute.
    ///     An empty file isn't stored, and its address has a zero hash.
    ///   - partition: The repository to store the content for.
    ///   - context: The 16-byte context of the content's address,
    ///     or `nil` for a zero context.
    ///   - uploading: Whether to write the content to the store's server;
    ///     see ``PutResult/isStoredLocally``.
    /// - Returns: The address of the content, and where the store put it.
    /// - Throws: ``LoreError`` if the store can't store the content,
    ///   such as ``LoreError/Code/invalidArguments``
    ///   for a path that doesn't exist or isn't a file.
    @discardableResult
    public func put(
        contentsOfFile path: String,
        in partition: RepositoryID,
        context: [UInt8]? = nil,
        uploading: Bool = false
    ) async throws -> PutResult {
        let context = try ContentStore.context(context)
        let path = Repository.absolutePath(of: path)
        return try await putItem(
            lore_storage_put_file_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_put_file_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_put_file_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.context = context
                item.pointee.path = arena.string(path)
                item.pointee.remote_write = UInt8(uploading)
                arguments.pointee.items = lore_storage_put_file_item_array_t(ptr: item, count: 1)
            }
        )
    }

    /// Reads content into memory.
    ///
    /// The method returns the whole content in one `Data` value.
    /// For large content, use ``writeContents(at:in:to:)``.
    ///
    /// - Parameters:
    ///   - address: The address of the content.
    ///     An address with a zero hash names empty content.
    ///   - partition: The repository whose content it is.
    /// - Returns: The content.
    /// - Throws: ``LoreError`` if the store can't read the content,
    ///   such as ``LoreError/Code/addressNotFound``.
    public func contents(at address: ContentAddress, in partition: RepositoryID) async throws -> Data {
        let buffer = ContentBuffer()
        let events = try await call(
            lore_storage_get_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_get_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_get_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.address = address.libraryValue
                // One event for each fragment,
                // so that the library doesn't hold the whole content too.
                item.pointee.streaming = 1
                arguments.pointee.items = lore_storage_get_item_array_t(ptr: item, count: 1)
            },
            transform: buffer.receive
        )
        try ContentStore.value(of: events)
        return buffer.data
    }

    /// Writes content to a file.
    ///
    /// The library writes the file itself,
    /// so you don't load the content into memory.
    /// It replaces a file at `path`.
    ///
    /// - Parameters:
    ///   - address: The address of the content.
    ///     An address with a zero hash names empty content.
    ///   - partition: The repository whose content it is.
    ///   - path: The path of the file to write,
    ///     relative to the current directory of the process unless it's absolute.
    /// - Throws: ``LoreError`` if the store can't read the content or write the file,
    ///   such as ``LoreError/Code/addressNotFound``.
    public func writeContents(at address: ContentAddress, in partition: RepositoryID, to path: String) async throws {
        let path = Repository.absolutePath(of: path)
        let events = try await call(
            lore_storage_get_file_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_get_file_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_get_file_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.address = address.libraryValue
                item.pointee.path = arena.string(path)
                arguments.pointee.items = lore_storage_get_file_item_array_t(ptr: item, count: 1)
            },
            transform: ItemEvent.getComplete
        )
        try ContentStore.value(of: events)
    }

    /// Returns how the store holds content, without reading the content.
    ///
    /// - Parameters:
    ///   - address: The address of the content.
    ///   - partition: The repository whose content it is.
    /// - Returns: The stored content,
    ///   or `nil` if the store doesn't hold content at the address.
    /// - Throws: ``LoreError`` if the store can't look up the content.
    public func storedContent(at address: ContentAddress, in partition: RepositoryID) async throws -> StoredContent? {
        let events = try await call(
            lore_storage_get_metadata_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_get_metadata_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_get_metadata_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.address = address.libraryValue
                arguments.pointee.items = lore_storage_get_metadata_item_array_t(ptr: item, count: 1)
            },
            transform: { event -> ItemEvent<StoredContent>? in
                guard event.pointee.tag == LORE_EVENT_STORAGE_GET_METADATA_ITEM_COMPLETE.rawValue else {
                    return nil
                }
                let data = event.pointee.storage_get_metadata_item_complete
                return ItemEvent(
                    error: data.error,
                    value: StoredContent(
                        address: ContentAddress(data.address),
                        size: Int(clamping: data.fragment.size_content),
                        payloadSize: Int(data.fragment.size_payload)
                    )
                )
            }
        )
        return try ContentStore.valueUnlessMissing(of: events)
    }

    /// Copies content to another repository's partition of the store,
    /// or to another context.
    ///
    /// The copy has the same hash as the content.
    /// A copy in a store without a server doesn't move the content's bytes.
    ///
    /// - Parameters:
    ///   - address: The address of the content.
    ///   - source: The repository whose content it is.
    ///   - target: The repository to copy the content to.
    ///   - context: The 16-byte context of the copy's address,
    ///     or `nil` to keep the context of `address`.
    /// - Returns: The address of the copy in `target`.
    /// - Throws: ``LoreError`` if the store can't copy the content,
    ///   such as ``LoreError/Code/addressNotFound``,
    ///   or ``LoreError/Code/invalidArguments``
    ///   for a copy to the same repository and context,
    ///   or for a context that doesn't hold 16 bytes.
    @discardableResult
    public func copy(
        _ address: ContentAddress,
        from source: RepositoryID,
        to target: RepositoryID,
        context: [UInt8]? = nil
    ) async throws -> ContentAddress {
        let targetContext = try ContentStore.context(context ?? address.context)
        let events = try await call(
            lore_storage_copy_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_copy_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_copy_item_t.self)
                item.pointee.id = 1
                item.pointee.source_partition = source.libraryValue
                item.pointee.target_partition = target.libraryValue
                item.pointee.source_address = address.libraryValue
                item.pointee.target_context = targetContext
                arguments.pointee.items = lore_storage_copy_item_array_t(ptr: item, count: 1)
            },
            transform: { event -> ItemEvent<ContentAddress>? in
                guard event.pointee.tag == LORE_EVENT_STORAGE_COPY_ITEM_COMPLETE.rawValue else {
                    return nil
                }
                let data = event.pointee.storage_copy_item_complete
                // The copy keeps the hash and takes the target context.
                var target = data.source_address
                target.context = data.target_context
                return ItemEvent(error: data.error, value: ContentAddress(target))
            }
        )
        return try ContentStore.value(of: events)
    }

    /// Writes the store's pending changes to disk.
    ///
    /// A store in memory has nothing to write.
    ///
    /// - Throws: ``LoreError`` if the library can't write the changes.
    public func flush() async throws {
        let events = try await call(
            lore_storage_flush_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_flush_args_t>, handle, _) in
                arguments.pointee.handle = handle
            },
            transform: { _ -> ItemEvent<Never>? in nil }
        )
        try ContentStore.check(events)
    }

    /// Permanently removes content from the local store and from the store's server.
    ///
    /// Obliterating can't be undone.
    /// The library removes the content at `address` in `partition`
    /// from the local store
    /// and, for a store with a server that isn't offline,
    /// from the server.
    /// The same content in another partition stays.
    /// Every revision of the repository with a file that has the content
    /// keeps its record of the file,
    /// but no longer has its content:
    /// reading the file at such a revision fails
    /// with ``LoreError/Code/addressNotFound``.
    /// Content that a side doesn't hold counts as removed from it.
    ///
    /// - Parameters:
    ///   - address: The address of the content.
    ///   - partition: The repository whose content it is.
    /// - Returns: The sides of the store that the obliteration acted on.
    /// - Throws: ``LoreError`` if either side can't remove the content.
    @discardableResult
    public func obliterate(_ address: ContentAddress, in partition: RepositoryID) async throws -> ObliterateResult {
        let hasServer = serverURL != nil
        let events = try await call(
            lore_storage_obliterate_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_obliterate_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_obliterate_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.address = address.libraryValue
                arguments.pointee.items = lore_storage_obliterate_item_array_t(ptr: item, count: 1)
            },
            transform: { event -> ItemEvent<ObliterateResult>? in
                guard event.pointee.tag == LORE_EVENT_STORAGE_OBLITERATE_ITEM_COMPLETE.rawValue else {
                    return nil
                }
                let data = event.pointee.storage_obliterate_item_complete
                return ItemEvent(
                    error: data.error,
                    value: ObliterateResult(
                        address: ContentAddress(data.address),
                        isRemovedLocally: Bool(data.local_success) && !Bool(data.local_skipped),
                        // Without a server, the library reports the server's side as a success.
                        isRemovedFromServer: hasServer && Bool(data.remote_success) && !Bool(data.remote_skipped)
                    )
                )
            }
        )
        return try ContentStore.value(of: events)
    }

    /// Writes content that the local store holds to the store's server.
    ///
    /// Use it for content that you put without `uploading`,
    /// or whose upload failed.
    ///
    /// - Parameters:
    ///   - address: The address of the content.
    ///   - partition: The repository whose content it is.
    /// - Returns: `true` if the method wrote the content to the server,
    ///   or `false` if the local store records that the server already has it.
    /// - Throws: ``LoreError`` if the store can't upload the content,
    ///   such as ``LoreError/Code/addressNotFound``
    ///   for content that the local store doesn't hold,
    ///   or ``LoreError/Code/invalidArguments``
    ///   for a store without a server or a store that's offline.
    @discardableResult
    public func upload(_ address: ContentAddress, in partition: RepositoryID) async throws -> Bool {
        let events = try await call(
            lore_storage_upload_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_upload_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_upload_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.address = address.libraryValue
                arguments.pointee.items = lore_storage_upload_item_array_t(ptr: item, count: 1)
            },
            transform: { event -> ItemEvent<Bool>? in
                guard event.pointee.tag == LORE_EVENT_STORAGE_UPLOAD_ITEM_COMPLETE.rawValue else {
                    return nil
                }
                let data = event.pointee.storage_upload_item_complete
                return ItemEvent(error: data.error, value: !Bool(data.already_durable))
            }
        )
        return try ContentStore.value(of: events)
    }
}

// MARK: - Published content

extension ContentStore {
    /// Stores content and publishes it under a key, in one call.
    ///
    /// The key, of type ``KeyType/published``, then names the content's hash,
    /// and ``contents(publishedAs:in:context:)`` reads the content.
    /// The library writes the key only after it stores the content,
    /// so the key never names content that the store doesn't hold.
    /// The last call to publish under a key wins.
    /// To detect that another caller of the same local store published first,
    /// ``put(_:in:context:uploading:)`` the content and then
    /// ``compareAndSwap(valueForKey:ofType:in:expecting:replacingWith:)``
    /// the key of type ``KeyType/published``;
    /// that doesn't detect a key that another computer published to the server.
    ///
    /// The method copies `data` into memory that the library reads during the call,
    /// so the content is in memory twice.
    /// For a file, use ``publish(contentsOfFile:as:in:context:uploading:)``.
    ///
    /// - Parameters:
    ///   - data: The content.
    ///     Empty content removes the key instead of publishing content:
    ///     from the local store,
    ///     and from the server if `uploading` is `true`.
    ///     A key that stays on the server resolves again on a later read.
    ///   - key: The key.
    ///   - partition: The repository to publish the content for.
    ///   - context: The 16-byte context of the content's address,
    ///     or `nil` for a zero context.
    ///     Pass the same context to read the key.
    ///   - uploading: Whether to write the content and the key to the store's server;
    ///     see ``PutResult/isStoredLocally``.
    /// - Returns: The address of the content that the key names, and where the store put it.
    /// - Throws: ``LoreError`` if the store can't store or publish the content,
    ///   such as ``LoreError/Code/invalidArguments`` for a key of all zeros.
    @discardableResult
    public func publish(
        _ data: Data,
        as key: Hash,
        in partition: RepositoryID,
        context: [UInt8]? = nil,
        uploading: Bool = false
    ) async throws -> PutResult {
        let context = try ContentStore.context(context)
        return try await putItem(
            lore_storage_put_resolved_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_put_resolved_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_put_resolved_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.key = key.libraryValue
                item.pointee.context = context
                item.pointee.data = arena.bytes(data)
                item.pointee.remote_write = UInt8(uploading)
                arguments.pointee.items = lore_storage_put_resolved_item_array_t(ptr: item, count: 1)
            }
        )
    }

    /// Stores the content of a file and publishes it under a key, in one call.
    ///
    /// See ``publish(_:as:in:context:uploading:)``.
    /// The library reads the file in parts,
    /// so the content is never in memory at once.
    ///
    /// - Parameters:
    ///   - path: The path of the file,
    ///     relative to the current directory of the process unless it's absolute.
    ///     An empty file removes the key instead of publishing content.
    ///   - key: The key.
    ///   - partition: The repository to publish the content for.
    ///   - context: The 16-byte context of the content's address,
    ///     or `nil` for a zero context.
    ///     Pass the same context to read the key.
    ///   - uploading: Whether to write the content and the key to the store's server;
    ///     see ``PutResult/isStoredLocally``.
    /// - Returns: The address of the content that the key names, and where the store put it.
    /// - Throws: ``LoreError`` if the store can't store or publish the content,
    ///   such as ``LoreError/Code/invalidArguments``
    ///   for a path that doesn't exist or isn't a file.
    @discardableResult
    public func publish(
        contentsOfFile path: String,
        as key: Hash,
        in partition: RepositoryID,
        context: [UInt8]? = nil,
        uploading: Bool = false
    ) async throws -> PutResult {
        let context = try ContentStore.context(context)
        let path = Repository.absolutePath(of: path)
        return try await putItem(
            lore_storage_put_file_resolved_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_put_file_resolved_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_put_file_resolved_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.key = key.libraryValue
                item.pointee.context = context
                item.pointee.path = arena.string(path)
                item.pointee.remote_write = UInt8(uploading)
                arguments.pointee.items = lore_storage_put_file_resolved_item_array_t(ptr: item, count: 1)
            }
        )
    }

    /// Reads the content that a key names into memory.
    ///
    /// The method resolves the key, of type ``KeyType/published``, to a hash,
    /// and reads the content at that hash and `context`, in one call.
    /// It returns the whole content in one `Data` value.
    /// For large content, use ``writeContents(publishedAs:in:context:to:)``.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - partition: The repository that published the content.
    ///   - context: The context that the content was published with,
    ///     or `nil` for a zero context.
    /// - Returns: The address and the content,
    ///   or `nil` if the key names no content
    ///   or the store doesn't hold the content it names.
    /// - Throws: ``LoreError`` if the store can't read the content,
    ///   or with ``LoreError/Code/invalidArguments``
    ///   for a context that doesn't hold 16 bytes.
    public func contents(
        publishedAs key: Hash,
        in partition: RepositoryID,
        context: [UInt8]? = nil
    ) async throws -> PublishedContent? {
        let context = try ContentStore.context(context)
        let buffer = ContentBuffer()
        let events = try await call(
            lore_storage_get_resolved_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_get_resolved_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_get_resolved_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.key = key.libraryValue
                item.pointee.context = context
                item.pointee.streaming = 1
                arguments.pointee.items = lore_storage_get_resolved_item_array_t(ptr: item, count: 1)
            },
            transform: buffer.receive
        )
        guard let address = try ContentStore.valueUnlessMissing(of: events) else {
            return nil
        }
        return PublishedContent(address: address, data: buffer.data)
    }

    /// Writes the content that a key names to a file.
    ///
    /// The method resolves the key, of type ``KeyType/published``, to a hash,
    /// and writes the content at that hash and `context`, in one call.
    /// The library writes the file in parts,
    /// so the content is never in memory at once.
    /// It replaces a file at `path`,
    /// and leaves the file unchanged if the key names no content.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - partition: The repository that published the content.
    ///   - context: The context that the content was published with,
    ///     or `nil` for a zero context.
    ///   - path: The path of the file to write,
    ///     relative to the current directory of the process unless it's absolute.
    /// - Returns: The address of the content,
    ///   or `nil` if the key names no content
    ///   or the store doesn't hold the content it names.
    /// - Throws: ``LoreError`` if the store can't read the content or write the file.
    @discardableResult
    public func writeContents(
        publishedAs key: Hash,
        in partition: RepositoryID,
        context: [UInt8]? = nil,
        to path: String
    ) async throws -> ContentAddress? {
        let context = try ContentStore.context(context)
        let path = Repository.absolutePath(of: path)
        let events = try await call(
            lore_storage_get_file_resolved_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_get_file_resolved_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_get_file_resolved_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.key = key.libraryValue
                item.pointee.context = context
                item.pointee.path = arena.string(path)
                arguments.pointee.items = lore_storage_get_file_resolved_item_array_t(ptr: item, count: 1)
            },
            transform: ItemEvent.getComplete
        )
        return try ContentStore.valueUnlessMissing(of: events)
    }
}

// MARK: - Mutable store

extension ContentStore {
    /// Returns the value of a key in the mutable store.
    ///
    /// The method reads only the local mutable store,
    /// also in a store with a server.
    /// To read content that a key on the server names,
    /// use ``contents(publishedAs:in:context:)``.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - type: The kind of value that the key refers to.
    ///   - partition: The repository whose key it is.
    /// - Returns: The value, or `nil` if the key has no value.
    /// - Throws: ``LoreError`` if the store can't read the key.
    public func value(
        forKey key: Hash,
        ofType type: KeyType = .untyped,
        in partition: RepositoryID
    ) async throws -> Hash? {
        let events = try await call(
            lore_storage_mutable_load_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_mutable_load_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_mutable_load_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.key = key.libraryValue
                item.pointee.key_type = lore_key_type_t(rawValue: type.rawValue)
                arguments.pointee.items = lore_storage_mutable_load_item_array_t(ptr: item, count: 1)
            },
            transform: { event -> ItemEvent<Hash?>? in
                guard event.pointee.tag == LORE_EVENT_STORAGE_MUTABLE_LOAD_ITEM_COMPLETE.rawValue else {
                    return nil
                }
                let data = event.pointee.storage_mutable_load_item_complete
                return ItemEvent(error: data.error, value: Hash(data.value))
            }
        )
        return try ContentStore.valueUnlessMissing(of: events) ?? nil
    }

    /// Sets or removes the value of a key in the mutable store.
    ///
    /// The method writes only the local mutable store,
    /// also in a store with a server.
    ///
    /// - Parameters:
    ///   - value: The value, or `nil` or the all-zero hash to remove the key.
    ///   - key: The key.
    ///   - type: The kind of value that the key refers to.
    ///   - partition: The repository whose key it is.
    /// - Throws: ``LoreError`` if the store can't write the key.
    public func setValue(
        _ value: Hash?,
        forKey key: Hash,
        ofType type: KeyType = .untyped,
        in partition: RepositoryID
    ) async throws {
        let events = try await call(
            lore_storage_mutable_store_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_mutable_store_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_mutable_store_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.key = key.libraryValue
                if let value {
                    item.pointee.value = value.libraryValue
                }
                item.pointee.key_type = lore_key_type_t(rawValue: type.rawValue)
                arguments.pointee.items = lore_storage_mutable_store_item_array_t(ptr: item, count: 1)
            },
            transform: { event -> ItemEvent<Void>? in
                guard event.pointee.tag == LORE_EVENT_STORAGE_MUTABLE_STORE_ITEM_COMPLETE.rawValue else {
                    return nil
                }
                return ItemEvent(error: event.pointee.storage_mutable_store_item_complete.error, value: ())
            }
        )
        try ContentStore.value(of: events)
    }

    /// Sets or removes the value of a key in the mutable store
    /// only if the key holds an expected value.
    ///
    /// The store compares and writes in one step,
    /// so another caller of the same local store can't change the key in between.
    /// The method uses only the local mutable store,
    /// also in a store with a server,
    /// so it doesn't see keys that other computers write to the server.
    /// A key that holds another value isn't an error:
    /// the result reports the value that the key holds.
    ///
    /// - Parameters:
    ///   - key: The key.
    ///   - type: The kind of value that the key refers to.
    ///   - partition: The repository whose key it is.
    ///   - expected: The value that the key must hold,
    ///     or `nil` or the all-zero hash for a key without a value.
    ///   - newValue: The value to set,
    ///     or `nil` or the all-zero hash to remove the key.
    /// - Returns: ``SwapResult/swapped`` if the key held `expected`,
    ///   or ``SwapResult/mismatched(current:)`` with the value that the key holds.
    /// - Throws: ``LoreError`` if the store can't read or write the key.
    public func compareAndSwap(
        valueForKey key: Hash,
        ofType type: KeyType = .untyped,
        in partition: RepositoryID,
        expecting expected: Hash?,
        replacingWith newValue: Hash?
    ) async throws -> SwapResult {
        let events = try await call(
            lore_storage_mutable_compare_and_swap_async,
            configure: {
                (arguments: UnsafeMutablePointer<lore_storage_mutable_compare_and_swap_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_mutable_compare_and_swap_item_t.self)
                item.pointee.id = 1
                item.pointee.partition = partition.libraryValue
                item.pointee.key = key.libraryValue
                if let expected {
                    item.pointee.expected = expected.libraryValue
                }
                if let newValue {
                    item.pointee.value = newValue.libraryValue
                }
                item.pointee.key_type = lore_key_type_t(rawValue: type.rawValue)
                arguments.pointee.items = lore_storage_mutable_compare_and_swap_item_array_t(ptr: item, count: 1)
            },
            transform: { event -> ItemEvent<Hash?>? in
                guard event.pointee.tag == LORE_EVENT_STORAGE_MUTABLE_COMPARE_AND_SWAP_ITEM_COMPLETE.rawValue else {
                    return nil
                }
                let data = event.pointee.storage_mutable_compare_and_swap_item_complete
                return ItemEvent(error: data.error, value: Hash(data.previous))
            }
        )
        // The library reports the value that the key held before the call,
        // which is the expected value when the swap took effect.
        let previous = try ContentStore.value(of: events)
        // The library reads an all-zero `expected` as "no value", as it does `nil`,
        // and reports "no value" as `nil`.
        let wanted = expected.flatMap { $0.isZero ? nil : $0 }
        return previous == wanted ? .swapped : .mismatched(current: previous)
    }

    /// Lists the keys of a kind in the mutable store, with their values.
    ///
    /// The method reads only the local store.
    /// In Lore 0.11.0, the list of ``KeyType/untyped`` keys is always empty.
    ///
    /// - Parameters:
    ///   - type: The kind of value that the keys refer to.
    ///   - partition: The repository whose keys to list,
    ///     or `nil` for every repository in the store.
    /// - Returns: The keys and their values, in no particular order.
    ///   The third byte of each key is the raw value of `type`;
    ///   see ``KeyType``.
    /// - Throws: ``LoreError`` if the store can't list the keys.
    public func entries(ofType type: KeyType, in partition: RepositoryID?) async throws -> [Entry] {
        let events = try await call(
            lore_storage_mutable_list_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_mutable_list_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let item = arena.allocate(lore_storage_mutable_list_item_t.self)
                item.pointee.id = 1
                if let partition {
                    item.pointee.partition = partition.libraryValue
                }
                item.pointee.key_type = lore_key_type_t(rawValue: type.rawValue)
                arguments.pointee.items = lore_storage_mutable_list_item_array_t(ptr: item, count: 1)
            },
            transform: ListEvent.init
        )
        try ContentStore.value(of: (events.events.compactMap(\.completion), events.error))
        return events.events.compactMap(\.entry)
    }
}

// MARK: - Revision trees

extension ContentStore {
    /// Loads the tree of a revision of the store's repository from the store.
    ///
    /// The tree is a ``RevisionTree``,
    /// like one from ``Repository/loadRevisionTree(of:)``,
    /// that reads and writes this store,
    /// so it can add content that you put in the store.
    /// It keeps the claim of the store until you close the tree,
    /// even if you close the store first.
    /// Call ``RevisionTree/close()`` when you're done with the tree.
    ///
    /// - Parameter revision: The revision, or `nil` for the current revision.
    /// - Returns: The loaded tree.
    /// - Throws: ``LoreError`` if the library can't load the tree,
    ///   such as ``LoreError/Code/revisionNotFound``,
    ///   or with ``LoreError/Code/invalidArguments``
    ///   for a store in memory.
    public func loadRevisionTree(of revision: RevisionSpecifier? = nil) async throws -> RevisionTree {
        try await loadRevisionTree { repository in
            try await repository.revision(revision).id
        }
    }

    /// Loads an empty tree from the store,
    /// to build a first revision of the store's repository.
    ///
    /// See ``Repository/loadEmptyRevisionTree()``.
    ///
    /// - Returns: The loaded tree.
    /// - Throws: ``LoreError`` if the library can't load the tree,
    ///   or with ``LoreError/Code/invalidArguments``
    ///   for a store in memory.
    public func loadEmptyRevisionTree() async throws -> RevisionTree {
        try await loadRevisionTree { _ in nil }
    }

    /// Loads a tree of the store's repository,
    /// with the revision that `revisionID` returns, or `nil` for an empty tree.
    private func loadRevisionTree(
        revisionID: (Repository) async throws -> RevisionID?
    ) async throws -> RevisionTree {
        // A closed store throws before the binding reads the repository.
        try await withHandle { handle in
            guard let repository, let repositoryID else {
                throw LoreError(code: .invalidArguments, message: "A store in memory has no revision trees.")
            }
            let revisionID = try await revisionID(repository)
            return try await repository.loadRevisionTree(
                revisionID: revisionID,
                repositoryID: repositoryID,
                store: handle,
                onRelease: nil
            )
        }
    }
}

// MARK: - Calls

extension ContentStore {
    /// The error that the methods of a closed store throw.
    static let closedError = LoreError(code: .invalidArguments, message: "The store is closed.")

    /// The repository whose global arguments calls on the store use.
    ///
    /// A store in memory uses no repository directory.
    private nonisolated var caller: Repository {
        repository ?? Repository(path: "", options: options)
    }

    /// Converts an optional 16-byte context to a library context.
    fileprivate static func context(_ bytes: [UInt8]?) throws -> lore_context_t {
        var context = lore_context_t()
        guard let bytes else {
            return context
        }
        guard bytes.count == 16 else {
            throw LoreError(code: .invalidArguments, message: "A context has 16 bytes, not \(bytes.count).")
        }
        setTupleBytes(&context.data, to: bytes)
        return context
    }

    /// Runs an operation with the store's handle,
    /// counting it as an active call that ``close()`` waits for.
    ///
    /// - Throws: ``closedError`` if the store is closed.
    private func withHandle<T: Sendable>(
        _ operation: (lore_store_t) async throws -> T
    ) async throws -> T {
        guard let handleID else {
            throw Self.closedError
        }
        activeCalls += 1
        defer {
            activeCalls -= 1
            if activeCalls == 0 {
                let waiters = closeWaiters
                closeWaiters = []
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        return try await operation(lore_store_t(handle_id: handleID))
    }

    /// Calls the library with the store's handle
    /// and returns the events and the error of the call.
    private func call<Arguments, Value: Sendable>(
        _ function:
            @escaping @Sendable (
                UnsafePointer<lore_global_args_t>?,
                UnsafePointer<Arguments>?,
                lore_event_callback_config_t
            ) -> Void,
        configure: @escaping @Sendable (UnsafeMutablePointer<Arguments>, lore_store_t, Arena) -> Void,
        transform: @escaping EventTransform<Value>
    ) async throws -> (events: [Value], error: LoreError?) {
        let caller = caller
        return try await withHandle { handle in
            await ContentStore.call(
                function,
                caller: caller,
                handle: handle,
                configure: configure,
                transform: transform
            )
        }
    }

    /// Stores one item with a put function and returns its result.
    private func putItem<Arguments>(
        _ function:
            @escaping @Sendable (
                UnsafePointer<lore_global_args_t>?,
                UnsafePointer<Arguments>?,
                lore_event_callback_config_t
            ) -> Void,
        configure: @escaping @Sendable (UnsafeMutablePointer<Arguments>, lore_store_t, Arena) -> Void
    ) async throws -> PutResult {
        let events = try await call(
            function,
            configure: configure,
            transform: { event -> ItemEvent<PutResult>? in
                guard event.pointee.tag == LORE_EVENT_STORAGE_PUT_ITEM_COMPLETE.rawValue else {
                    return nil
                }
                let data = event.pointee.storage_put_item_complete
                return ItemEvent(
                    error: data.error,
                    value: PutResult(
                        address: ContentAddress(data.address),
                        isStoredLocally: Bool(data.stored_local),
                        isStoredOnServer: Bool(data.stored_remote)
                    )
                )
            }
        )
        return try ContentStore.value(of: events)
    }

    private nonisolated static func call<Arguments, Value: Sendable>(
        _ function:
            @escaping @Sendable (
                UnsafePointer<lore_global_args_t>?,
                UnsafePointer<Arguments>?,
                lore_event_callback_config_t
            ) -> Void,
        caller: Repository,
        handle: lore_store_t,
        configure: @escaping @Sendable (UnsafeMutablePointer<Arguments>, lore_store_t, Arena) -> Void,
        transform: @escaping EventTransform<Value>
    ) async -> (events: [Value], error: LoreError?) {
        let arena = Arena()
        let globals = caller.globals(in: arena)
        let arguments = arena.allocate(Arguments.self)
        configure(arguments, handle, arena)
        // The library reads some arguments, such as the bytes to store,
        // until it ends the call.
        return await collect(transform, keepingAlive: arena) { callback in
            function(globals, arguments, callback)
        }
    }

    /// Throws the error of a call, if it failed.
    private static func check<Value>(_ result: (events: [Value], error: LoreError?)) throws {
        if let error = result.error {
            throw error
        }
    }

    /// Returns the value of the single item of a call,
    /// or `nil` if the item reports that the store doesn't hold what it names.
    ///
    /// The library reports the outcome of each item on an event of its own,
    /// so the binding can tell a missing item from a failed call
    /// without reading the error message.
    private static func valueUnlessMissing<Value>(
        of result: (events: [ItemEvent<Value>], error: LoreError?)
    ) throws -> Value? {
        if let item = result.events.last, let code = item.error?.code,
            code == .addressNotFound || code == .notFound
        {
            return nil
        }
        return try value(of: result)
    }

    /// Returns the value of the single item of a call.
    @discardableResult
    private static func value<Value>(of result: (events: [ItemEvent<Value>], error: LoreError?)) throws -> Value {
        if let error = result.error {
            throw error
        }
        guard let item = result.events.last else {
            throw LoreError.missingEvent("the outcome of the item")
        }
        if let error = item.error {
            throw error
        }
        return item.value
    }
}

/// The outcome of one item of a storage call.
private struct ItemEvent<Value: Sendable>: Sendable {
    /// The error of the item, or `nil` if it succeeded.
    var error: LoreError?

    /// The value of the item.
    var value: Value

    init(error: lore_error_detail_t, value: Value) {
        self.error = error.error_code == 0 ? nil : LoreError(status: error.error_code, detail: error)
        self.value = value
    }
}

extension ItemEvent where Value == ContentAddress {
    /// Converts the event that ends an item of a get call.
    static func getComplete(_ event: UnsafePointer<lore_event_t>) -> Self? {
        guard event.pointee.tag == LORE_EVENT_STORAGE_GET_ITEM_COMPLETE.rawValue else {
            return nil
        }
        let data = event.pointee.storage_get_item_complete
        return ItemEvent(error: data.error, value: ContentAddress(data.address))
    }
}

/// An event of a call that lists keys in the mutable store.
private enum ListEvent: Sendable {
    case entry(ContentStore.Entry)
    case complete(ItemEvent<Void>)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_STORAGE_MUTABLE_LIST_ENTRY.rawValue:
            let data = event.pointee.storage_mutable_list_entry
            guard let key = ContentStore.Hash(data.key), let value = ContentStore.Hash(data.value) else {
                return nil
            }
            self = .entry(ContentStore.Entry(key: key, value: value))
        case LORE_EVENT_STORAGE_MUTABLE_LIST_ITEM_COMPLETE.rawValue:
            self = .complete(ItemEvent(error: event.pointee.storage_mutable_list_item_complete.error, value: ()))
        default:
            return nil
        }
    }

    var entry: ContentStore.Entry? {
        if case .entry(let entry) = self { entry } else { nil }
    }

    var completion: ItemEvent<Void>? {
        if case .complete(let completion) = self { completion } else { nil }
    }
}

/// Assembles the content of an item of a get call from its events.
///
/// The library reports the size of the content
/// and then the bytes of each part with its offset,
/// on its worker threads.
/// The buffer copies the bytes as they arrive,
/// so the call keeps only one copy of the content.
private final class ContentBuffer: Sendable {
    private let storage = Mutex(Data())

    /// The content.
    var data: Data {
        storage.withLock { $0 }
    }

    /// Copies the bytes of an event,
    /// and converts the event that ends the item.
    @Sendable func receive(_ event: UnsafePointer<lore_event_t>) -> ItemEvent<ContentAddress>? {
        switch event.pointee.tag {
        case LORE_EVENT_STORAGE_GET_HEADER.rawValue:
            let size = Int(clamping: event.pointee.storage_get_header.size_content)
            storage.withLock { $0 = Data(count: size) }
            return nil
        case LORE_EVENT_STORAGE_GET_DATA.rawValue:
            let data = event.pointee.storage_get_data
            guard let pointer = data.bytes.ptr, data.bytes.len > 0 else {
                return nil
            }
            let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(data.bytes.len))
            let offset = Int(clamping: data.offset)
            storage.withLock { content in
                let end = offset + bytes.count
                if content.count < end {
                    content.count = end
                }
                content.replaceSubrange(offset ..< end, with: bytes)
            }
            return nil
        default:
            return ItemEvent.getComplete(event)
        }
    }
}
