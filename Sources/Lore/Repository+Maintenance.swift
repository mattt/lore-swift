import CLore
import Foundation

// MARK: - Configuration

extension Repository {
    /// A key of the configuration file in a repository's `.lore` directory.
    public struct ConfigurationKey: RawRepresentable, Sendable, Hashable, ExpressibleByStringLiteral {
        /// The name of the key in the configuration file.
        public var rawValue: String

        /// Creates a key from its name.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.init(rawValue: value)
        }

        /// The URL of the repository's server.
        public static let remoteURL: Self = "remote_url"

        /// The identity that the repository's commits record.
        public static let identity: Self = "identity"
    }

    /// Reads a value from the repository's configuration file.
    ///
    /// The method reads the file in the repository's `.lore` directory
    /// and doesn't connect to the server.
    ///
    /// - Parameter key: The key.
    ///   Lore 0.11.0 reads only ``ConfigurationKey/remoteURL``
    ///   and ``ConfigurationKey/identity``.
    /// - Returns: The value, or `nil` if the configuration has no value for the key.
    /// - Throws: ``LoreError`` if the library can't read the configuration,
    ///   or with ``LoreError/Code/internal`` for a key that it doesn't read.
    public func configurationValue(forKey key: ConfigurationKey) async throws -> String? {
        let values = try await perform(
            lore_repository_config_get_async,
            offline: true,
            configure: { (arguments: UnsafeMutablePointer<lore_repository_config_get_args_t>, arena) in
                arguments.pointee.key = arena.string(key.rawValue)
            },
            transform: { event -> String? in
                guard event.pointee.tag == LORE_EVENT_REPOSITORY_CONFIG_GET.rawValue else {
                    return nil
                }
                return String(event.pointee.repository_config_get.value)
            }
        )
        guard let value = values.last else {
            throw LoreError.missingEvent("the configuration value")
        }
        return value.isEmpty ? nil : value
    }
}

// MARK: - State dumps

/// The tree of a repository's state,
/// as ``Repository/stateDump(of:under:maximumDepth:)`` reports it for diagnosis.
public struct StateDump: Sendable, Hashable {
    /// A node of the tree.
    public struct Node: Sendable, Hashable {
        /// The path of the node, relative to the repository directory,
        /// with a trailing `/` for a directory.
        ///
        /// The paths of the nodes in a linked repository
        /// start with the path of the link.
        public var path: String

        /// The number of the node in its state.
        public var id: UInt32

        /// The number of the node's parent.
        public var parentID: UInt32

        /// The number of the node's next sibling, or 0 for none.
        public var siblingID: UInt32

        /// The file mode of the node.
        public var mode: UInt16

        /// The size of the node's content, in bytes.
        public var size: Int

        /// The flags of the node.
        public var flags: UInt16

        /// A description of the node's kind and target that the library formats,
        /// such as `addr <address>` for a file,
        /// `child <number>` for a directory,
        /// or `link <repository> rev <revision> node <number>` for a link.
        public var detail: String
    }

    /// The identifier of the repository.
    public var repositoryID: RepositoryID

    /// The revision of the state,
    /// or `nil` for a repository without revisions.
    ///
    /// For the staged state,
    /// this is the identifier that the library gives the staged state,
    /// which no revision has.
    public var revision: RevisionID?

    /// The number of the revision,
    /// or 0 for the staged state.
    public var revisionNumber: Int

    /// The 32 bytes of the hash of the state's node tree.
    public var treeHash: [UInt8]

    /// The size of the node tree, in bytes.
    public var treeSize: Int

    /// The nodes, in depth-first order,
    /// with the nodes of each directory in the order that the state records them.
    public var nodes: [Node]
}

extension Repository {
    /// Reports the tree of a state of the repository, for diagnosis.
    ///
    /// - Parameters:
    ///   - revision: The revision,
    ///     or `nil` for the staged state if there is one,
    ///     and for the current revision otherwise.
    ///   - path: The path of the directory or file to start from,
    ///     relative to the repository directory,
    ///     or `nil` for the whole tree.
    ///     The nodes include the node at the path.
    ///   - maximumDepth: The number of levels of the tree to report,
    ///     or `nil` for every level.
    /// - Returns: The state and its nodes.
    /// - Throws: ``LoreError`` if the library can't read the state,
    ///   such as ``LoreError/Code/revisionNotFound``,
    ///   or ``LoreError/Code/nodeNotFound`` for a path that the state doesn't have.
    public func stateDump(
        of revision: RevisionSpecifier? = nil,
        under path: String? = nil,
        maximumDepth: Int? = nil
    ) async throws -> StateDump {
        let events = try await perform(
            lore_repository_dump_async,
            configure: { (arguments: UnsafeMutablePointer<lore_repository_dump_args_t>, arena) in
                arguments.pointee.revision = arena.string(revision?.rawValue)
                arguments.pointee.path = arena.string(path)
                arguments.pointee.max_depth = UInt(clamping: max(maximumDepth ?? 0, 0))
            },
            transform: StateDumpEvent.init
        )
        var dump: StateDump?
        for event in events {
            switch event {
            case .begin(let repositoryID):
                dump = StateDump(
                    repositoryID: repositoryID,
                    revisionNumber: 0,
                    treeHash: [],
                    treeSize: 0,
                    nodes: []
                )
            case .state(let revision, let number, let treeHash, let treeSize):
                dump?.revision = revision
                dump?.revisionNumber = number
                dump?.treeHash = treeHash
                dump?.treeSize = treeSize
            case .node(let node):
                dump?.nodes.append(node)
            }
        }
        guard let dump else {
            throw LoreError.missingEvent("the repository")
        }
        return dump
    }
}

/// An event of a state dump.
private enum StateDumpEvent: Sendable {
    case begin(RepositoryID)
    case state(RevisionID?, number: Int, treeHash: [UInt8], treeSize: Int)
    case node(StateDump.Node)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_REPOSITORY_DUMP_BEGIN.rawValue:
            guard let id = RepositoryID(event.pointee.repository_dump_begin.repository) else {
                return nil
            }
            self = .begin(id)
        case LORE_EVENT_REPOSITORY_STATE_DUMP.rawValue:
            let data = event.pointee.repository_state_dump
            self = .state(
                RevisionID(data.revision),
                number: Int(clamping: data.revision_number),
                treeHash: tupleBytes(data.tree_hash.data),
                treeSize: Int(clamping: data.tree_size)
            )
        case LORE_EVENT_REPOSITORY_STATE_DUMP_NODE.rawValue:
            let data = event.pointee.repository_state_dump_node
            self = .node(
                StateDump.Node(
                    path: String(data.name),
                    id: data.id,
                    parentID: data.parent,
                    siblingID: data.sibling,
                    mode: data.mode,
                    size: Int(clamping: data.size),
                    flags: data.flags,
                    detail: String(data.type_data)
                )
            )
        default:
            return nil
        }
    }
}

// MARK: - Stores

/// What a store holds at an address,
/// as ``Repository/storeEntries(for:includingSubfragments:checkingServer:)`` reports it.
public struct StoreEntry: Sendable, Hashable {
    /// How much of an address a store matched.
    public enum Match: UInt32, Sendable, Hashable {
        /// The store holds the address:
        /// its hash with the context of this repository.
        case address = 0
        /// The store holds the hash for this repository with another context.
        case hashInRepository = 1
        /// The store holds the hash only for another repository.
        case hashInOtherRepository = 2
        /// The store doesn't hold the hash.
        case notFound = 3
    }

    /// The address that the entry describes.
    public var address: ContentAddress

    /// A Boolean value that indicates whether the entry describes the server's store
    /// rather than the local one.
    public var isOnServer: Bool

    /// How much of the address the store matched.
    public var match: Match

    /// A Boolean value that indicates whether the store holds the payload,
    /// and not only a record of the content.
    public var hasPayload: Bool

    /// A Boolean value that indicates whether the address is a part
    /// of the content at the address that you asked for.
    public var isSubfragment: Bool

    /// The library's flags for the stored content.
    public var flags: UInt32

    /// The size of the stored payload, in bytes.
    public var payloadSize: Int

    /// The size of the content, in bytes.
    public var contentSize: Int
}

extension Repository {
    /// Reports what the repository's store,
    /// and optionally its server's store,
    /// hold at an address.
    ///
    /// The local store comes first.
    /// For content that the library stores in parts,
    /// the parts follow the content that they belong to
    /// if you ask for them.
    ///
    /// - Parameters:
    ///   - address: The address,
    ///     such as the ``StoredContent/address`` of ``storedContent(of:)``.
    ///   - includingSubfragments: Whether to report the parts of content
    ///     that the local store holds in parts.
    ///   - checkingServer: Whether to ask the server too.
    ///     The library skips the server for an offline repository.
    /// - Returns: The entries.
    /// - Throws: ``LoreError`` if the library can't read the store.
    public func storeEntries(
        for address: ContentAddress,
        includingSubfragments: Bool = false,
        checkingServer: Bool = true
    ) async throws -> [StoreEntry] {
        try await perform(
            lore_repository_store_immutable_query_async,
            offline: !checkingServer,
            configure: {
                (arguments: UnsafeMutablePointer<lore_repository_store_immutable_query_args_t>, arena) in
                arguments.pointee.address = arena.string(address.description)
                arguments.pointee.recurse = UInt8(includingSubfragments)
            },
            transform: { event -> StoreEntry? in
                guard event.pointee.tag == LORE_EVENT_REPOSITORY_STORE_IMMUTABLE_QUERY.rawValue else {
                    return nil
                }
                let data = event.pointee.repository_store_immutable_query
                return StoreEntry(
                    address: ContentAddress(data.address),
                    isOnServer: Bool(data.remote),
                    match: StoreEntry.Match(rawValue: data.status) ?? .notFound,
                    hasPayload: Bool(data.payload),
                    isSubfragment: Bool(data.subfragment),
                    flags: data.flags,
                    payloadSize: Int(data.payload_size),
                    contentSize: Int(clamping: data.content_size)
                )
            }
        )
    }

    /// Checks the integrity of the repository's local store
    /// and of the node tree of its state.
    ///
    /// The method checks the staged state if there is one,
    /// and the current revision otherwise.
    /// It doesn't connect to the server.
    ///
    /// - Parameters:
    ///   - path: The path of the directory or file whose nodes to check,
    ///     relative to the repository directory,
    ///     or `nil` for the whole tree.
    ///     The method checks the whole local store either way.
    ///   - healing: Whether to repair what the check finds.
    ///     A repaired tree becomes the repository's staged state.
    /// - Returns: `true` if the method repaired the tree and staged it,
    ///   or `false` otherwise.
    /// - Throws: ``LoreError`` if the check fails
    ///   or finds a problem that it doesn't repair,
    ///   such as ``LoreError/Code/nodeNotFound`` for a path that the state doesn't have.
    @discardableResult
    public func verifyState(of path: String? = nil, healing: Bool = false) async throws -> Bool {
        let healed = try await perform(
            lore_repository_verify_state_async,
            offline: true,
            configure: { (arguments: UnsafeMutablePointer<lore_repository_verify_state_args_t>, arena) in
                arguments.pointee.path = arena.string(path)
                arguments.pointee.heal = UInt8(healing)
            },
            transform: { event -> Bool? in
                guard event.pointee.tag == LORE_EVENT_REPOSITORY_VERIFY_STATE_END.rawValue else {
                    return nil
                }
                // A zero hash means that nothing was healed.
                return tupleBytes(event.pointee.repository_verify_state_end.healed_staged_state.data)
                    .contains { $0 != 0 }
            }
        )
        guard let result = healed.last else {
            throw LoreError.missingEvent("the end of the verification")
        }
        return result
    }

    /// Collects garbage in the repository's local store.
    ///
    /// The library evicts the least recently used content
    /// beyond the capacity that the repository's store configuration sets
    /// and compacts the store's files beyond the size that it sets.
    /// A repository created with the library's defaults sets neither,
    /// and then the method changes nothing.
    /// Evicted content can't be restored from the local store.
    /// The method doesn't connect to the server.
    ///
    /// - Throws: ``LoreError`` if the library can't collect garbage.
    public func collectGarbage() async throws {
        _ = try await perform(
            lore_repository_gc_async,
            offline: true,
            configure: { (_: UnsafeMutablePointer<lore_repository_gc_args_t>, _) in },
            transform: { _ -> Never? in nil }
        )
    }

    /// Waits for the library's background work to finish.
    ///
    /// In Lore 0.11.0,
    /// the method waits for the background work of every repository in the process,
    /// not only this one.
    ///
    /// - Throws: ``LoreError`` if the library reports a failure.
    public func flush() async throws {
        _ = try await perform(
            lore_repository_flush_async,
            offline: true,
            configure: { (_: UnsafeMutablePointer<lore_repository_flush_args_t>, _) in },
            transform: { _ -> Never? in nil }
        )
    }

    /// Releases the store data that the library caches in memory
    /// for the repository's directory.
    ///
    /// The method frees memory and doesn't change the repository.
    /// The library closes a store on disk once nothing uses it,
    /// and the next operation opens it again.
    ///
    /// - Throws: ``LoreError`` if the library reports a failure.
    public func releaseStores() async throws {
        _ = try await perform(
            lore_repository_release_async,
            offline: true,
            configure: { (_: UnsafeMutablePointer<lore_repository_release_args_t>, _) in },
            transform: { _ -> Never? in nil }
        )
    }
}

// MARK: - Instances

/// A checkout of a repository that the repository's store records.
///
/// Every checkout registers itself in the store that it uses.
/// Checkouts that use the same shared store
/// see each other's registrations.
public struct RepositoryInstance: Sendable, Hashable, Identifiable {
    /// The reason that a registration no longer describes a checkout.
    public enum Staleness: UInt8, Sendable, Hashable {
        /// Nothing exists at the path.
        case pathMissing = 1
        /// The directory at the path holds another instance,
        /// such as after the repository was created or cloned there again.
        case superseded = 2
        /// The directory at the path holds no checkout.
        case noCheckout = 3
    }

    /// The identifier of the instance.
    public var id: InstanceID

    /// The path of the checkout that the registration records.
    public var path: String

    /// The name of the checkout's current branch,
    /// or an empty string if the store doesn't record one.
    public var branch: String

    /// The identifier of the checkout's current branch.
    public var branchID: BranchID?

    /// The checkout's current revision.
    public var revision: RevisionID?

    /// The reason that the registration is stale,
    /// or `nil` for a registration that describes a checkout.
    public var staleness: Staleness?
}

extension Repository {
    /// Returns the instances that the repository's store records,
    /// stale ones included.
    ///
    /// The registration of this checkout's own instance is never stale.
    /// It keeps the path where the checkout was created or cloned
    /// until ``updateInstancePath()`` records a new one.
    /// The method reads the local store
    /// and doesn't connect to the server.
    ///
    /// - Returns: The instances that describe a checkout,
    ///   followed by the stale ones.
    /// - Throws: ``LoreError`` if the library can't read the store.
    public func instances() async throws -> [RepositoryInstance] {
        try await perform(
            lore_repository_instance_list_async,
            offline: true,
            configure: { (_: UnsafeMutablePointer<lore_repository_instance_list_args_t>, _) in },
            transform: RepositoryInstance.init
        )
    }

    /// Removes the stale instances from the repository's store.
    ///
    /// An instance is stale if nothing exists at its path,
    /// if the directory at its path holds no checkout,
    /// or if that directory holds another instance.
    /// The method removes only those registrations,
    /// and no files,
    /// and it never removes this checkout's own registration.
    /// To register a checkout again,
    /// call ``updateInstancePath()`` in it.
    /// The method doesn't connect to the server.
    ///
    /// - Returns: The instances that the method removed.
    /// - Throws: ``LoreError`` if the library can't change the store.
    @discardableResult
    public func pruneStaleInstances() async throws -> [RepositoryInstance] {
        try await perform(
            lore_repository_instance_prune_async,
            offline: true,
            configure: { (_: UnsafeMutablePointer<lore_repository_instance_prune_args_t>, _) in },
            transform: RepositoryInstance.init
        )
    }

    /// Records the repository directory as the path of this checkout's instance,
    /// such as after you move the directory.
    ///
    /// The method also removes the registration of any other instance
    /// at the same path.
    /// It doesn't connect to the server.
    ///
    /// In Lore 0.11.0,
    /// moving the directory right after a commit in the same process
    /// often left the checkout without a current revision.
    /// Calling ``flush()`` and ``releaseStores()`` before the move
    /// made that rarer, but didn't prevent it.
    ///
    /// - Throws: ``LoreError`` if the library can't change the store.
    public func updateInstancePath() async throws {
        _ = try await perform(
            lore_repository_update_path_async,
            offline: true,
            configure: { (_: UnsafeMutablePointer<lore_repository_update_path_args_t>, _) in },
            transform: { _ -> Never? in nil }
        )
    }
}

extension RepositoryInstance {
    /// Copies an instance event.
    fileprivate init?(_ event: UnsafePointer<lore_event_t>) {
        guard event.pointee.tag == LORE_EVENT_REPOSITORY_INSTANCE.rawValue else {
            return nil
        }
        let data = event.pointee.repository_instance
        self.init(
            id: InstanceID(data.instance_id),
            path: String(data.path),
            branch: String(data.branch_name),
            branchID: BranchID(data.branch),
            revision: RevisionID(data.revision),
            staleness: Staleness(rawValue: data.stale)
        )
    }
}
