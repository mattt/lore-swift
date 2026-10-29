import CLore
import Foundation

/// The tree of a revision, loaded into memory
/// so that you can read and edit it without a working directory.
///
/// Load a tree with ``Repository/loadRevisionTree(of:)``
/// or ``Repository/loadEmptyRevisionTree()``,
/// or from an open store with ``ContentStore/loadRevisionTree(of:)``
/// or ``ContentStore/loadEmptyRevisionTree()``.
/// A tree belongs to one repository
/// and holds one revision at a time.
/// Edits to the tree,
/// and the metadata that you set on it,
/// stay in memory until ``commit(message:)``
/// writes them to the repository's local store as a new revision
/// and makes it the latest revision of its branch.
/// The working directory and its staged changes don't change.
///
/// Nodes are identified by ``NodeID``.
/// Add content by its ``ContentAddress`` in the repository's store,
/// such as the address of another file
/// or of content that you put with ``ContentStore/put(_:in:context:uploading:)``.
///
/// A loaded tree holds library resources
/// and the claim of the repository's store,
/// which makes other processes that use the store wait,
/// until you call ``close()``.
/// After ``close()``, every other method throws ``LoreError``
/// with ``LoreError/Code/invalidArguments``
/// without calling the library,
/// and ``close()`` does nothing.
/// If you release the last reference to a tree without closing it,
/// its deinitializer starts the library call that closes it
/// and returns without waiting for the call to end;
/// edits that you haven't committed are lost.
/// The library closes a tree once:
/// a tree that you closed doesn't close it again.
///
/// The tree runs one method at a time, in the order of the calls,
/// so that a method starts only after the previous one ends.
/// The library lets calls on one tree overlap,
/// but overlapping moves can leave a tree that the library refuses to commit.
public actor RevisionTree {
    /// The repository that the tree was loaded from.
    public nonisolated let repository: Repository

    /// The identifier of the repository that the tree belongs to.
    public nonisolated let repositoryID: RepositoryID

    /// The library's identifier for the tree,
    /// or `nil` once the tree is closed.
    private var handleID: UInt64?

    /// Runs once, when the library ends the call that closes the tree,
    /// with the error if the call failed.
    private let onRelease: (@Sendable (LoreError?) -> Void)?

    /// Whether a method is running.
    private var isBusy = false

    /// The methods that wait for the running method to end, in the order of their calls.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        repository: Repository,
        repositoryID: RepositoryID,
        handleID: UInt64,
        onRelease: (@Sendable (LoreError?) -> Void)? = nil
    ) {
        self.repository = repository
        self.repositoryID = repositoryID
        self.handleID = handleID
        self.onRelease = onRelease
    }

    deinit {
        // `close()` clears the identifier before it calls the library,
        // so a closed tree isn't closed again.
        // A deinitializer can't wait,
        // so it only starts the call;
        // the call's callback context holds no reference to the tree.
        guard let handleID else {
            return
        }
        RevisionTree.release(handleID, repository: repository, onRelease: onRelease)
    }

    /// A Boolean value that indicates whether the tree is closed.
    public var isClosed: Bool {
        handleID == nil
    }

    /// The identifier of the library resource, for tests.
    var libraryHandleID: UInt64? {
        handleID
    }

    /// Releases the tree's library resources and the claim of the repository's store.
    ///
    /// The library waits for the calls on the tree that are running to end.
    /// Edits that you haven't committed are lost.
    /// Closing a tree again does nothing.
    ///
    /// - Throws: ``LoreError`` if the library can't close the tree.
    ///   The tree is closed either way.
    public func close() async throws {
        await acquire()
        defer { relinquish() }
        guard let handleID else {
            return
        }
        self.handleID = nil
        let repository = repository
        let onRelease = onRelease
        do {
            _ = try await repository.perform(
                lore_revision_tree_close_async,
                configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_close_args_t>, _) in
                    arguments.pointee.handle = lore_revision_tree_t(handle_id: handleID)
                },
                transform: { _ -> Never? in nil }
            )
        } catch {
            onRelease?(error as? LoreError)
            throw error
        }
        onRelease?(nil)
    }

    /// Starts the library call that closes a tree, without waiting for it to end.
    nonisolated static func release(
        _ handleID: UInt64,
        repository: Repository,
        onRelease: (@Sendable (LoreError?) -> Void)?
    ) {
        let arena = Arena()
        let globals = repository.globals(in: arena)
        let arguments = arena.allocate(lore_revision_tree_close_args_t.self)
        arguments.pointee.handle = lore_revision_tree_t(handle_id: handleID)
        detach(
            onEnd: { error in onRelease?(error) },
            start: { callback in
                withExtendedLifetime(arena) {
                    lore_revision_tree_close_async(globals, arguments, callback)
                }
            }
        )
    }
}

// MARK: - Loading

extension Repository {
    /// Loads the tree of a revision into memory,
    /// to read or edit it without the working directory.
    ///
    /// The tree reads the repository's local store,
    /// so the revision must be one that this checkout has.
    /// For a repository without revisions,
    /// use ``loadEmptyRevisionTree()``.
    /// Call ``RevisionTree/close()`` when you're done with the tree.
    ///
    /// A commit from the tree succeeds only while the loaded revision
    /// is the latest revision of its branch,
    /// unless the tree's `branch` metadata value names a new branch
    /// whose branch point is the loaded revision.
    ///
    /// - Parameter revision: The revision, or `nil` for the current revision.
    /// - Returns: The loaded tree.
    /// - Throws: ``LoreError`` if the library can't load the tree,
    ///   such as ``LoreError/Code/revisionNotFound``.
    public func loadRevisionTree(of revision: RevisionSpecifier? = nil) async throws -> RevisionTree {
        try await loadRevisionTree(of: revision, onRelease: nil)
    }

    /// Loads an empty tree into memory,
    /// to build a first revision without the working directory.
    ///
    /// The library needs a branch for the first revision:
    /// set the tree's `branch` metadata value
    /// to the ``MetadataValue/context(_:)`` with the bytes of a ``BranchID``,
    /// such as the ``Status/branchID`` of a repository without revisions,
    /// before you commit.
    /// Call ``RevisionTree/close()`` when you're done with the tree.
    ///
    /// - Returns: The loaded tree.
    /// - Throws: ``LoreError`` if the library can't load the tree.
    public func loadEmptyRevisionTree() async throws -> RevisionTree {
        try await loadRevisionTree(revisionID: nil, onRelease: nil)
    }

    /// Loads the tree of a revision,
    /// with an operation that runs when the library closes the tree, for tests.
    func loadRevisionTree(
        of revision: RevisionSpecifier?,
        onRelease: (@Sendable (LoreError?) -> Void)?
    ) async throws -> RevisionTree {
        let revisionID = try await self.revision(revision).id
        return try await loadRevisionTree(revisionID: revisionID, onRelease: onRelease)
    }

    func loadRevisionTree(
        revisionID: RevisionID?,
        onRelease: (@Sendable (LoreError?) -> Void)?
    ) async throws -> RevisionTree {
        let repositoryID = try await state().repositoryID
        let directory = absolutePath
        let stores = try await perform(
            lore_storage_open_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_open_args_t>, arena) in
                arguments.pointee.repository_path = arena.string(directory)
            },
            transform: { event -> UInt64? in
                guard event.pointee.tag == LORE_EVENT_STORAGE_OPENED.rawValue else {
                    return nil
                }
                return event.pointee.storage_opened.handle_id
            }
        )
        guard let storeID = stores.last else {
            throw LoreError.missingEvent("a store")
        }
        let tree: RevisionTree
        do {
            tree = try await loadRevisionTree(
                revisionID: revisionID,
                repositoryID: repositoryID,
                store: lore_store_t(handle_id: storeID),
                onRelease: onRelease
            )
        } catch {
            try? await closeStore(storeID)
            throw error
        }
        // The tree keeps the store's claim until the tree is closed,
        // so the binding closes its handle to the store at once.
        // If that fails, releasing the tree closes it.
        try await closeStore(storeID)
        return tree
    }

    /// Loads the tree of a revision of this repository from an open store.
    ///
    /// - Parameter revisionID: The revision, or `nil` for an empty tree.
    func loadRevisionTree(
        revisionID: RevisionID?,
        repositoryID: RepositoryID,
        store: lore_store_t,
        onRelease: (@Sendable (LoreError?) -> Void)?
    ) async throws -> RevisionTree {
        let trees = try await perform(
            lore_revision_tree_load_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_load_args_t>, _) in
                arguments.pointee.store = store
                arguments.pointee.repository = repositoryID.libraryValue
                if let revisionID {
                    arguments.pointee.revision_hash = revisionID.libraryValue
                }
            },
            transform: { event -> UInt64? in
                guard event.pointee.tag == LORE_EVENT_REVISION_TREE_LOADED.rawValue else {
                    return nil
                }
                return event.pointee.revision_tree_loaded.handle_id
            }
        )
        guard let handleID = trees.last else {
            throw LoreError.missingEvent("a revision tree")
        }
        return RevisionTree(repository: self, repositoryID: repositoryID, handleID: handleID, onRelease: onRelease)
    }

    /// Closes a handle to the repository's store.
    private func closeStore(_ storeID: UInt64) async throws {
        _ = try await perform(
            lore_storage_close_async,
            configure: { (arguments: UnsafeMutablePointer<lore_storage_close_args_t>, _) in
                arguments.pointee.handle = lore_store_t(handle_id: storeID)
            },
            transform: { _ -> Never? in nil }
        )
    }
}

// MARK: - Nodes

extension RevisionTree {
    /// The identifier of a node in a revision tree.
    ///
    /// An identifier names a node only in the tree that reports it.
    public struct NodeID: RawRepresentable, Sendable, Hashable {
        /// The raw value of the identifier.
        public var rawValue: UInt32

        /// Creates an identifier from its raw value.
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// The root directory of a tree.
        public static let root = Self(rawValue: 0)
    }

    /// The change to a node that a tree holds for the next commit.
    ///
    /// Corresponds to `lore_node_staged_action_t`.
    public struct StagedAction: RawRepresentable, Sendable, Hashable {
        /// The raw value of the action.
        public var rawValue: UInt32

        /// Creates an action from its raw value.
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// The node is unchanged.
        public static let unchanged = Self(rawValue: LORE_NODE_STAGED_ACTION_NONE.rawValue)
        /// The node was added.
        public static let add = Self(rawValue: LORE_NODE_STAGED_ACTION_ADD.rawValue)
        /// The content of the node was modified.
        public static let modify = Self(rawValue: LORE_NODE_STAGED_ACTION_MODIFY.rawValue)
        /// The node was deleted.
        public static let delete = Self(rawValue: LORE_NODE_STAGED_ACTION_DELETE.rawValue)
        /// The node was moved or renamed.
        public static let move = Self(rawValue: LORE_NODE_STAGED_ACTION_MOVE.rawValue)
        /// The node was copied from another node.
        public static let copy = Self(rawValue: LORE_NODE_STAGED_ACTION_COPY.rawValue)
    }

    /// A file, directory, or link in a revision tree.
    public struct Node: Sendable, Hashable, Identifiable {
        /// The identifier of the node.
        public var id: NodeID

        /// The name of the node in its parent directory,
        /// or an empty string for the root directory.
        public var name: String

        /// The identifier of the node's parent directory.
        public var parentID: NodeID

        /// The kind of node,
        /// or `nil` for a kind that the binding doesn't know.
        ///
        /// A node of kind ``NodeKind/symbolicLink`` is a link to another repository's tree.
        public var kind: NodeKind?

        /// The change to the node that the tree holds for the next commit.
        ///
        /// A deleted node of the loaded revision stays in the tree
        /// with ``StagedAction/delete`` until the commit;
        /// see ``RevisionTree/delete(_:)``.
        public var stagedAction: StagedAction

        /// The file mode of the node.
        public var mode: UInt16

        /// The size of the node's content, in bytes.
        public var size: Int

        /// The address of the node's content in the store,
        /// or `nil` for a node without one,
        /// such as a directory that the tree added.
        ///
        /// The context of a file's address is the file's identity,
        /// which a move keeps
        /// and a modification keeps unless it gives another context.
        public var address: ContentAddress?

        /// The identifier of the repository whose tree the node belongs to.
        public var repositoryID: RepositoryID?

        /// The revision whose tree the node belongs to.
        public var revision: RevisionID?
    }

    /// A node that a path names.
    public struct ResolvedPath: Sendable, Hashable {
        /// The identifier of the node.
        ///
        /// It names a node of this tree
        /// only if ``repositoryID`` and ``revision`` are this tree's.
        public var nodeID: NodeID

        /// The identifier of the repository whose tree the node belongs to,
        /// which differs from the tree's for a path inside a link.
        public var repositoryID: RepositoryID?

        /// The revision whose tree the node belongs to.
        public var revision: RevisionID?
    }

    /// The record of the revision that a tree holds.
    public struct Info: Sendable, Hashable {
        /// The identifier of the repository.
        public var repositoryID: RepositoryID?

        /// The revision,
        /// or `nil` for an empty tree that has no revision yet.
        public var revision: RevisionID?

        /// The parents of the revision.
        public var parents: [RevisionID]

        /// The time the revision was created.
        public var creationDate: Date?

        /// The identity of the revision's author,
        /// or `nil` if the revision doesn't record one.
        public var creator: String?

        /// The number of metadata values of the revision.
        public var metadataCount: Int
    }
}

extension RevisionTree.StagedAction: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unchanged: "unchanged"
        case .add: "add"
        case .modify: "modify"
        case .delete: "delete"
        case .move: "move"
        case .copy: "copy"
        default: "action \(rawValue)"
        }
    }
}

extension RevisionTree {
    /// Reads the record of the revision that the tree holds.
    ///
    /// - Returns: The record.
    /// - Throws: ``LoreError`` if the library can't read the record.
    public func info() async throws -> Info {
        let infos = try await perform(
            lore_revision_tree_info_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_info_args_t>, handle, _) in
                arguments.pointee.handle = handle
            },
            transform: { event -> Info? in
                guard event.pointee.tag == LORE_EVENT_REVISION_TREE_INFO.rawValue else {
                    return nil
                }
                let data = event.pointee.revision_tree_info
                return Info(
                    repositoryID: RepositoryID(data.repository),
                    revision: RevisionID(data.revision),
                    parents: [RevisionID(data.parent.0), RevisionID(data.parent.1)].compactMap { $0 },
                    creationDate: data.creation_timestamp > 0
                        ? Date(millisecondsSince1970: UInt64(data.creation_timestamp)) : nil,
                    creator: data.author_identity.length > 0 ? String(data.author_identity) : nil,
                    metadataCount: Int(data.metadata_key_count)
                )
            }
        )
        guard let info = infos.last else {
            throw LoreError.missingEvent("the revision record")
        }
        return info
    }

    /// Finds the node at a path.
    ///
    /// - Parameter path: The path, relative to the root of the tree,
    ///   or an empty string for the root directory.
    /// - Returns: The node at the path.
    /// - Throws: ``LoreError`` if the library can't resolve the path.
    ///   Lore 0.12.0 reports a path without a node
    ///   with ``LoreError/Code/invalidArguments``.
    public func resolve(_ path: String) async throws -> ResolvedPath {
        let resolved = try await perform(
            lore_revision_tree_resolve_path_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_resolve_path_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                arguments.pointee.path = arena.string(path)
            },
            transform: { event -> ResolvedPath? in
                guard event.pointee.tag == LORE_EVENT_REVISION_TREE_RESOLVE_PATH_COMPLETE.rawValue else {
                    return nil
                }
                let data = event.pointee.revision_tree_resolve_path_complete
                return ResolvedPath(
                    nodeID: NodeID(rawValue: data.node_id),
                    repositoryID: RepositoryID(data.repository),
                    revision: RevisionID(data.revision)
                )
            }
        )
        guard let resolved = resolved.last else {
            throw LoreError.missingEvent("a node")
        }
        return resolved
    }

    /// Lists the nodes in a directory.
    ///
    /// - Parameter directory: The directory, or ``NodeID/root`` for the root directory.
    /// - Returns: The nodes in the directory,
    ///   including the nodes of the loaded revision that are deleted.
    ///   The nodes in a link belong to the linked repository's tree.
    /// - Throws: ``LoreError`` if the library can't list the directory,
    ///   such as ``LoreError/Code/invalidArguments`` for a node that isn't a directory.
    public func children(of directory: NodeID = .root) async throws -> [Node] {
        let events = try await perform(
            lore_revision_tree_list_children_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_list_children_args_t>, handle, _) in
                arguments.pointee.handle = handle
                arguments.pointee.parent_node_id = directory.rawValue
            },
            transform: ChildEvent.init
        )
        var tree: (RepositoryID?, RevisionID?) = (nil, nil)
        var nodes: [Node] = []
        for event in events {
            switch event {
            case .begin(let repositoryID, let revision):
                tree = (repositoryID, revision)
            case .child(var node):
                node.repositoryID = tree.0
                node.revision = tree.1
                nodes.append(node)
            }
        }
        return nodes
    }

    /// Reads a node.
    ///
    /// - Parameter id: The identifier of the node.
    /// - Returns: The node.
    /// - Throws: ``LoreError`` if the library can't read the node,
    ///   such as ``LoreError/Code/invalidArguments`` for an unknown identifier.
    public func node(_ id: NodeID) async throws -> Node {
        let nodes = try await perform(
            lore_revision_tree_node_info_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_node_info_args_t>, handle, _) in
                arguments.pointee.handle = handle
                arguments.pointee.node_id = id.rawValue
            },
            transform: { event -> Node? in
                guard event.pointee.tag == LORE_EVENT_REVISION_TREE_NODE_INFO.rawValue else {
                    return nil
                }
                let data = event.pointee.revision_tree_node_info
                return Node(
                    id: NodeID(rawValue: data.node_id),
                    name: String(data.name),
                    parentID: NodeID(rawValue: data.parent_id),
                    kind: NodeKind(rawValue: data.kind),
                    stagedAction: StagedAction(rawValue: data.staged_action),
                    mode: data.mode,
                    size: Int(clamping: data.size),
                    address: Node.address(data.address),
                    repositoryID: RepositoryID(data.repository),
                    revision: RevisionID(data.revision)
                )
            }
        )
        guard let node = nodes.last else {
            throw LoreError.missingEvent("a node")
        }
        return node
    }

    /// Returns the path of a node.
    ///
    /// - Parameter id: The identifier of the node.
    /// - Returns: The path of the node, relative to the root of the tree,
    ///   or an empty string for the root directory.
    /// - Throws: ``LoreError`` if the library can't find the node,
    ///   such as ``LoreError/Code/invalidArguments`` for an unknown identifier.
    public func path(of id: NodeID) async throws -> String {
        let paths = try await perform(
            lore_revision_tree_node_path_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_node_path_args_t>, handle, _) in
                arguments.pointee.handle = handle
                arguments.pointee.node_id = id.rawValue
            },
            transform: { event -> String? in
                guard event.pointee.tag == LORE_EVENT_REVISION_TREE_NODE_PATH.rawValue else {
                    return nil
                }
                return String(event.pointee.revision_tree_node_path.path)
            }
        )
        guard let path = paths.last else {
            throw LoreError.missingEvent("a path")
        }
        return path
    }
}

extension RevisionTree.Node {
    /// Copies a library address,
    /// returning `nil` for the all-zero address.
    fileprivate static func address(_ address: lore_address_t) -> ContentAddress? {
        let address = ContentAddress(address)
        return address.isZero ? nil : address
    }
}

/// An event of a call that lists the nodes in a directory.
private enum ChildEvent: Sendable {
    case begin(RepositoryID?, RevisionID?)
    case child(RevisionTree.Node)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_REVISION_TREE_LIST_CHILDREN_BEGIN.rawValue:
            let data = event.pointee.revision_tree_list_children_begin
            self = .begin(RepositoryID(data.repository), RevisionID(data.revision))
        case LORE_EVENT_REVISION_TREE_CHILD.rawValue:
            let data = event.pointee.revision_tree_child
            self = .child(
                RevisionTree.Node(
                    id: RevisionTree.NodeID(rawValue: data.node_id),
                    name: String(data.name),
                    parentID: RevisionTree.NodeID(rawValue: data.parent_id),
                    kind: NodeKind(rawValue: data.kind),
                    stagedAction: RevisionTree.StagedAction(rawValue: data.staged_action),
                    mode: data.mode,
                    size: Int(clamping: data.size),
                    address: RevisionTree.Node.address(data.address)
                )
            )
        default:
            return nil
        }
    }
}

// MARK: - Editing

extension RevisionTree {
    /// A node to add to a tree.
    public struct NewNode: Sendable, Hashable {
        /// The directory that a new node goes in.
        public enum Parent: Sendable, Hashable {
            /// A directory that the tree has.
            case node(NodeID)
            /// A directory that an earlier node in the same call adds,
            /// by its index in the call's array.
            case entry(Int)
        }

        /// The directory that the node goes in.
        public var parent: Parent

        /// The name of the node in its directory.
        public var name: String

        /// The kind of node.
        public private(set) var kind: NodeKind

        /// The file mode of the node.
        public var mode: UInt16

        /// The size of the node's content, in bytes.
        public var size: Int

        /// The address of the node's content in the store.
        public var address: ContentAddress?

        /// A new directory.
        ///
        /// - Parameters:
        ///   - name: The name of the directory.
        ///   - parent: The directory that the new directory goes in.
        public static func directory(named name: String, in parent: Parent) -> Self {
            Self(parent: parent, name: name, kind: .directory, mode: 0, size: 0, address: nil)
        }

        /// A new file with content that the repository's store holds.
        ///
        /// - Parameters:
        ///   - name: The name of the file.
        ///   - parent: The directory that the file goes in.
        ///   - address: The address of the file's content in the store.
        ///     The context of the address is the identity of the file.
        ///     A zero context gives the file a new identity,
        ///     except when the file restores a deleted node,
        ///     which keeps its identity; see ``RevisionTree/delete(_:)``.
        ///     The ``StoredContent/address`` of another file carries that file's identity,
        ///     so give a copy a zero context.
        ///   - size: The size of the content, in bytes.
        ///   - mode: The file mode.
        public static func file(
            named name: String,
            in parent: Parent,
            address: ContentAddress,
            size: Int,
            mode: UInt16 = 0
        ) -> Self {
            Self(parent: parent, name: name, kind: .file, mode: mode, size: size, address: address)
        }
    }

    /// New content for a file in a tree.
    public struct Modification: Sendable, Hashable {
        /// The file.
        public var node: NodeID

        /// The address of the file's new content in the store.
        ///
        /// An address with a zero context keeps the identity of the file.
        /// Another context replaces the file's identity,
        /// so the commit records the edit as a move.
        public var address: ContentAddress

        /// The size of the new content, in bytes.
        public var size: Int

        /// The file mode.
        public var mode: UInt16

        /// Creates new content for a file.
        ///
        /// - Parameters:
        ///   - node: The file.
        ///   - address: The address of the new content in the store.
        ///   - size: The size of the new content, in bytes.
        ///   - mode: The file mode.
        public init(node: NodeID, address: ContentAddress, size: Int, mode: UInt16 = 0) {
            self.node = node
            self.address = address
            self.size = size
            self.mode = mode
        }
    }

    /// A move of a node in a tree.
    public struct Move: Sendable, Hashable {
        /// The node to move.
        public var node: NodeID

        /// The directory to move the node to.
        ///
        /// The node's current directory renames it.
        public var destination: NodeID

        /// The name of the node in the destination.
        public var name: String

        /// Creates a move of a node.
        ///
        /// - Parameters:
        ///   - node: The node to move.
        ///   - destination: The directory to move the node to.
        ///   - name: The name of the node in the destination.
        public init(node: NodeID, to destination: NodeID, name: String) {
            self.node = node
            self.destination = destination
            self.name = name
        }
    }

    /// Adds nodes to the tree.
    ///
    /// The library checks every node before it adds any,
    /// so a node that it rejects leaves the tree unchanged.
    ///
    /// - Parameter nodes: The nodes to add.
    /// - Returns: The identifiers of the new nodes, in the order of `nodes`.
    /// - Throws: ``LoreError`` if the library can't add the nodes,
    ///   such as ``LoreError/Code/invalidArguments``
    ///   for a name that the directory already has
    ///   or a parent that isn't an earlier node in `nodes`,
    ///   or with ``LoreError/Code/invalidArguments``
    ///   for a parent index outside `nodes` or a negative size.
    @discardableResult
    public func add(_ nodes: [NewNode]) async throws -> [NodeID] {
        for node in nodes {
            if case .entry(let index) = node.parent, !nodes.indices.contains(index) {
                throw LoreError(code: .invalidArguments, message: "No new node has the index \(index).")
            }
            try RevisionTree.checkSize(node.size)
        }
        let added = try await perform(
            lore_revision_tree_add_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_add_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let entries = arena.allocate(lore_revision_tree_add_entry_t.self, count: nodes.count)
                for (index, node) in nodes.enumerated() {
                    entries[index].entry_id = UInt64(index + 1)
                    switch node.parent {
                    case .node(let id):
                        entries[index].parent_node_id = id.rawValue
                    case .entry(let entry):
                        entries[index].parent_node_id = RevisionTree.invalidNode
                        entries[index].parent_entry_index = UInt32(entry)
                    }
                    entries[index].name = arena.string(node.name)
                    entries[index].kind = node.kind.rawValue
                    entries[index].mode = node.mode
                    entries[index].size = UInt64(node.size)
                    if let address = node.address {
                        entries[index].address = address.libraryValue
                    }
                }
                arguments.pointee.entries = lore_revision_tree_add_entry_array_t(
                    ptr: entries,
                    count: UInt(nodes.count)
                )
            },
            transform: { event -> (entry: UInt64, node: NodeID)? in
                guard event.pointee.tag == LORE_EVENT_REVISION_TREE_ADD_COMPLETE.rawValue else {
                    return nil
                }
                let data = event.pointee.revision_tree_add_complete
                return (data.entry_id, NodeID(rawValue: data.node_id))
            }
        )
        // The library adds the nodes of different directories concurrently,
        // so it reports them in no particular order.
        let ids = Dictionary(added.map { ($0.entry, $0.node) }, uniquingKeysWith: { _, last in last })
        return try nodes.indices.map { index in
            guard let id = ids[UInt64(index + 1)] else {
                throw LoreError.missingEvent("a new node")
            }
            return id
        }
    }

    /// Deletes nodes from the tree,
    /// with everything in the directories among them.
    ///
    /// A node of the loaded revision stays in the tree
    /// with ``StagedAction/delete`` until the commit,
    /// and adding a node of the same kind with the same name
    /// to the same directory restores it.
    /// Restoring a directory doesn't restore its contents:
    /// they stay deleted until you add each of them back.
    /// A node that the tree added since it was loaded is removed at once,
    /// and adding it back makes a new node.
    ///
    /// - Parameter nodes: The nodes to delete.
    /// - Returns: The number of nodes deleted, including the nodes in deleted directories.
    /// - Throws: ``LoreError`` if the library can't delete the nodes,
    ///   such as ``LoreError/Code/invalidArguments`` for the root directory
    ///   or for a node inside a directory that `nodes` also deletes.
    ///   The library then deletes none of the nodes.
    @discardableResult
    public func delete(_ nodes: [NodeID]) async throws -> Int {
        let counts = try await perform(
            lore_revision_tree_delete_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_delete_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let entries = arena.allocate(lore_revision_tree_delete_entry_t.self, count: nodes.count)
                for (index, node) in nodes.enumerated() {
                    entries[index].entry_id = UInt64(index + 1)
                    entries[index].node_id = node.rawValue
                }
                arguments.pointee.entries = lore_revision_tree_delete_entry_array_t(
                    ptr: entries,
                    count: UInt(nodes.count)
                )
            },
            transform: { event -> Int? in
                guard event.pointee.tag == LORE_EVENT_REVISION_TREE_DELETE_COMPLETE.rawValue else {
                    return nil
                }
                return Int(clamping: event.pointee.revision_tree_delete_complete.node_count)
            }
        )
        return counts.reduce(0, +)
    }

    /// Replaces the content of files in the tree.
    ///
    /// - Parameter modifications: The files and their new content.
    /// - Throws: ``LoreError`` if the library can't modify the files,
    ///   such as ``LoreError/Code/invalidArguments`` for a node that isn't a file,
    ///   or with ``LoreError/Code/invalidArguments`` for a negative size.
    public func modify(_ modifications: [Modification]) async throws {
        for modification in modifications {
            try RevisionTree.checkSize(modification.size)
        }
        _ = try await perform(
            lore_revision_tree_modify_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_modify_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let entries = arena.allocate(lore_revision_tree_modify_entry_t.self, count: modifications.count)
                for (index, modification) in modifications.enumerated() {
                    entries[index].entry_id = UInt64(index + 1)
                    entries[index].node_id = modification.node.rawValue
                    entries[index].mode = modification.mode
                    entries[index].size = UInt64(modification.size)
                    entries[index].address = modification.address.libraryValue
                }
                arguments.pointee.entries = lore_revision_tree_modify_entry_array_t(
                    ptr: entries,
                    count: UInt(modifications.count)
                )
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Moves or renames nodes in the tree.
    ///
    /// A moved node keeps its identifier and its identity,
    /// so the commit records a move rather than a deletion and an addition.
    /// The library applies the moves in order
    /// and checks the tree that all of them produce:
    /// a name that one move frees, another move can take.
    ///
    /// - Parameter moves: The moves.
    /// - Throws: ``LoreError`` if the library can't move the nodes,
    ///   such as ``LoreError/Code/invalidArguments``
    ///   for a name that the destination already has
    ///   or a destination inside the moved node.
    public func move(_ moves: [Move]) async throws {
        _ = try await perform(
            lore_revision_tree_move_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_move_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let entries = arena.allocate(lore_revision_tree_move_entry_t.self, count: moves.count)
                for (index, move) in moves.enumerated() {
                    entries[index].entry_id = UInt64(index + 1)
                    entries[index].node_id = move.node.rawValue
                    entries[index].destination_parent_id = move.destination.rawValue
                    entries[index].dst_name = arena.string(move.name)
                }
                arguments.pointee.entries = lore_revision_tree_move_entry_array_t(
                    ptr: entries,
                    count: UInt(moves.count)
                )
            },
            transform: { _ -> Never? in nil }
        )
    }
}

// MARK: - Metadata

extension RevisionTree {
    /// Returns the metadata values for keys
    /// that the tree holds for the next commit.
    ///
    /// The tree holds the values that you set with ``setMetadata(_:)``
    /// and, after a commit that failed,
    /// the `message`, `created-by`, and `committed-by` values
    /// that ``commit(message:)`` set.
    /// The branch and the time that the library adds during a commit
    /// aren't among them.
    ///
    /// - Parameters:
    ///   - keys: The metadata keys.
    ///   - includingLoadedRevision: Whether to read a key that the tree has no value for
    ///     from the revision that the tree was loaded from.
    ///     The commit doesn't record those values.
    /// - Returns: The values, by key, without the keys that have no value.
    /// - Throws: ``LoreError`` if the library can't read the metadata.
    public func metadata(
        forKeys keys: [String],
        includingLoadedRevision: Bool = false
    ) async throws -> [String: MetadataValue] {
        let repository = repository
        return try await withHandle { handle in
            try await RevisionTree.readMetadata(
                forKeys: keys,
                includingLoadedRevision: includingLoadedRevision,
                repository: repository,
                handle: handle
            )
        }
    }

    /// Returns the metadata value for a key
    /// that the tree holds for the next commit.
    ///
    /// See ``metadata(forKeys:includingLoadedRevision:)`` for the values that the tree holds.
    ///
    /// - Parameters:
    ///   - key: The metadata key.
    ///   - includingLoadedRevision: Whether to read the key from the revision
    ///     that the tree was loaded from
    ///     if the tree has no value for it.
    ///     The commit doesn't record that value.
    /// - Returns: The value, or `nil` if there's no value for the key.
    /// - Throws: ``LoreError`` if the library can't read the metadata.
    public func metadata(forKey key: String, includingLoadedRevision: Bool = false) async throws -> MetadataValue? {
        try await metadata(forKeys: [key], includingLoadedRevision: includingLoadedRevision)[key]
    }

    /// Sets metadata values for the next commit.
    ///
    /// The tree keeps the values in memory until the commit.
    /// The commit records only the values that you set,
    /// none from the revision that the tree was loaded from,
    /// and adds the branch, the time,
    /// and the identity from the repository's options or configuration
    /// if you don't set them; see ``commit(message:)``.
    /// Unlike ``Repository/setRevisionMetadata(_:)``,
    /// this method sets values of every type,
    /// including ``MetadataValue/binary(_:)``
    /// and ``MetadataValue/address(hash:context:)``.
    ///
    /// - Parameter values: The values to set, by key.
    /// - Throws: ``LoreError`` if the library can't set the metadata,
    ///   or with ``LoreError/Code/invalidArguments``
    ///   for a hash, context, or address with the wrong number of bytes.
    public func setMetadata(_ values: [String: MetadataValue]) async throws {
        for (key, value) in values {
            try value.checkByteCounts(forKey: key)
        }
        let repository = repository
        try await withHandle { handle in
            try await RevisionTree.writeMetadata(values, repository: repository, handle: handle)
        }
    }

    /// Removes metadata values that you set for the next commit.
    ///
    /// The values of the revision that the tree was loaded from don't change.
    ///
    /// - Parameter keys: The metadata keys.
    /// - Returns: The keys that had a value.
    /// - Throws: ``LoreError`` if the library can't clear the metadata.
    @discardableResult
    public func clearMetadata(keys: [String]) async throws -> Set<String> {
        let removed = try await perform(
            lore_revision_tree_metadata_clear_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_metadata_clear_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let entries = arena.allocate(lore_revision_tree_metadata_clear_entry_t.self, count: keys.count)
                for (index, key) in keys.enumerated() {
                    entries[index].entry_id = UInt64(index + 1)
                    entries[index].key = arena.string(key)
                }
                arguments.pointee.entries = lore_revision_tree_metadata_clear_entry_array_t(
                    ptr: entries,
                    count: UInt(keys.count)
                )
            },
            transform: { event -> UInt64? in
                guard event.pointee.tag == LORE_EVENT_REVISION_TREE_METADATA_CLEAR_COMPLETE.rawValue else {
                    return nil
                }
                let data = event.pointee.revision_tree_metadata_clear_complete
                return Bool(data.removed) ? data.entry_id : nil
            }
        )
        return Set(
            removed.compactMap { entry in
                keys.indices.contains(Int(entry) - 1) ? keys[Int(entry) - 1] : nil
            }
        )
    }

    private nonisolated static func readMetadata(
        forKeys keys: [String],
        includingLoadedRevision: Bool,
        repository: Repository,
        handle: lore_revision_tree_t
    ) async throws -> [String: MetadataValue] {
        let entries = try await call(
            lore_revision_tree_metadata_get_async,
            repository: repository,
            handle: handle,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_metadata_get_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                arguments.pointee.include_revision = UInt8(includingLoadedRevision)
                let entries = arena.allocate(lore_revision_tree_metadata_get_entry_t.self, count: keys.count)
                for (index, key) in keys.enumerated() {
                    entries[index].entry_id = UInt64(index + 1)
                    entries[index].key = arena.string(key)
                }
                arguments.pointee.entries = lore_revision_tree_metadata_get_entry_array_t(
                    ptr: entries,
                    count: UInt(keys.count)
                )
            },
            transform: { event -> (key: String, value: MetadataValue?, code: Int32)? in
                guard event.pointee.tag == LORE_EVENT_REVISION_TREE_METADATA_GET_COMPLETE.rawValue else {
                    return nil
                }
                let data = event.pointee.revision_tree_metadata_get_complete
                return (String(data.key), MetadataValue(data.value), data.error_code.rawValue)
            }
        )
        var values: [String: MetadataValue] = [:]
        for entry in entries {
            // The library reports a value that it can't decode on the value's own event.
            guard entry.code == 0, let value = entry.value else {
                throw LoreError(
                    code: entry.code == 0 ? .internal : LoreError.Code(rawValue: entry.code),
                    message: "The library can't read the metadata value for \(entry.key)."
                )
            }
            values[entry.key] = value
        }
        return values
    }

    /// Sets metadata values whose byte counts are checked.
    private nonisolated static func writeMetadata(
        _ values: [String: MetadataValue],
        repository: Repository,
        handle: lore_revision_tree_t
    ) async throws {
        let entries = values.sorted { $0.key < $1.key }
        _ = try await call(
            lore_revision_tree_metadata_set_async,
            repository: repository,
            handle: handle,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_metadata_set_args_t>, handle, arena) in
                arguments.pointee.handle = handle
                let buffer = arena.allocate(lore_revision_tree_metadata_set_entry_t.self, count: entries.count)
                for (index, entry) in entries.enumerated() {
                    buffer[index].entry_id = UInt64(index + 1)
                    buffer[index].key = arena.string(entry.key)
                    // A stored property, so the key path names its memory.
                    entry.value.write(to: (buffer + index).pointer(to: \.value)!, in: arena)
                }
                arguments.pointee.entries = lore_revision_tree_metadata_set_entry_array_t(
                    ptr: buffer,
                    count: UInt(entries.count)
                )
            },
            transform: { _ -> Never? in nil }
        )
    }
}

// MARK: - Committing

extension RevisionTree {
    /// Commits the tree as a new revision
    /// and makes it the latest revision of its branch.
    ///
    /// The new revision is in the repository's local store,
    /// and its parent is the revision that the tree held.
    /// The working directory stays at its revision:
    /// sync it to the new revision with ``Repository/sync(to:discardingLocalChanges:)``
    /// before you commit or push from it.
    ///
    /// The commit records the metadata that you set with ``setMetadata(_:)``,
    /// the branch and the time,
    /// and, as `created-by` and `committed-by` if you don't set them,
    /// the identity in the repository's ``Repository/Options/identity``
    /// or else in its configuration.
    /// The library doesn't record an identity for a tree commit,
    /// so this method sets those values before it commits.
    /// Because they count as metadata to commit,
    /// a tree without edits commits a revision with the same files
    /// whenever there's an identity.
    ///
    /// The tree then holds the new revision:
    /// its node identifiers stay valid,
    /// its metadata for the next commit is empty,
    /// and later edits commit on top of it.
    /// If the commit fails, the tree keeps its edits and its metadata,
    /// including `message` and the identity values that this method set,
    /// so you can fix the problem and commit again.
    ///
    /// - Parameter message: The commit message,
    ///   or `nil` to use the `message` value that you set, if any.
    /// - Returns: The new revision, with its metadata.
    /// - Throws: ``LoreError`` if the library can't commit the tree.
    ///   Lore 0.12.0 reports a branch whose latest revision is no longer the one that the tree held,
    ///   and a tree without edits, metadata, a message, or an identity,
    ///   with ``LoreError/Code/internal``.
    @discardableResult
    public func commit(message: String? = nil) async throws -> Revision {
        let repository = repository
        let repositoryID = repositoryID
        return try await withHandle { handle in
            var values: [String: MetadataValue] = [:]
            if let message {
                values["message"] = .string(message)
            }
            // Lore 0.12.0 records the identity of the user
            // only for operations on a working directory,
            // although the header says that a tree commit records it.
            let identity: String?
            // An empty identity in the options means none, as it does for other operations.
            if let configured = repository.options.identity, !configured.isEmpty {
                identity = configured
            } else {
                identity = try await repository.configurationValue(forKey: .identity)
            }
            if let identity, !identity.isEmpty {
                let keys = ["created-by", "committed-by"]
                let current = try await RevisionTree.readMetadata(
                    forKeys: keys,
                    includingLoadedRevision: false,
                    repository: repository,
                    handle: handle
                )
                for key in keys where current[key] == nil {
                    values[key] = .string(identity)
                }
            }
            if !values.isEmpty {
                try await RevisionTree.writeMetadata(values, repository: repository, handle: handle)
            }
            let events = try await RevisionTree.call(
                lore_revision_tree_commit_async,
                repository: repository,
                handle: handle,
                configure: { (arguments: UnsafeMutablePointer<lore_revision_tree_commit_args_t>, handle, _) in
                    arguments.pointee.handle = handle
                },
                transform: CommitEvent.init
            )
            guard let committed = CommitEvent.revision(of: repositoryID, in: events) else {
                throw LoreError.missingEvent("a revision")
            }
            // The commit reports the new revision without its metadata.
            return try await repository.revision(.id(committed.id))
        }
    }
}

// MARK: - Calls

extension RevisionTree {
    /// The node identifier that the library reads as "none".
    fileprivate static let invalidNode: UInt32 = 0xFFFF_FFFF

    /// Checks that a content size isn't negative.
    fileprivate static func checkSize(_ size: Int) throws {
        guard size >= 0 else {
            throw LoreError(code: .invalidArguments, message: "The size must be at least 0, not \(size).")
        }
    }

    /// The error that the methods of a closed tree throw.
    static let closedError = LoreError(code: .invalidArguments, message: "The revision tree is closed.")

    /// Waits for the running method to end.
    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Lets the next waiting method run.
    private func relinquish() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Runs an operation with the tree's handle, after the running method ends.
    ///
    /// - Throws: ``closedError`` if the tree is closed.
    private func withHandle<T: Sendable>(
        _ operation: (lore_revision_tree_t) async throws -> T
    ) async throws -> T {
        await acquire()
        defer { relinquish() }
        guard let handleID else {
            throw Self.closedError
        }
        return try await operation(lore_revision_tree_t(handle_id: handleID))
    }

    /// Calls the library with the tree's handle, after the running method ends.
    private func perform<Arguments, Event: Sendable>(
        _ function:
            @escaping @Sendable (
                UnsafePointer<lore_global_args_t>?,
                UnsafePointer<Arguments>?,
                lore_event_callback_config_t
            ) -> Void,
        configure: @escaping @Sendable (UnsafeMutablePointer<Arguments>, lore_revision_tree_t, Arena) -> Void,
        transform: @escaping EventTransform<Event>
    ) async throws -> [Event] {
        let repository = repository
        return try await withHandle { handle in
            try await RevisionTree.call(
                function,
                repository: repository,
                handle: handle,
                configure: configure,
                transform: transform
            )
        }
    }

    nonisolated static func call<Arguments, Event: Sendable>(
        _ function:
            @escaping @Sendable (
                UnsafePointer<lore_global_args_t>?,
                UnsafePointer<Arguments>?,
                lore_event_callback_config_t
            ) -> Void,
        repository: Repository,
        handle: lore_revision_tree_t,
        configure: @escaping @Sendable (UnsafeMutablePointer<Arguments>, lore_revision_tree_t, Arena) -> Void,
        transform: @escaping EventTransform<Event>
    ) async throws -> [Event] {
        try await repository.perform(
            function,
            configure: { arguments, arena in configure(arguments, handle, arena) },
            transform: transform
        )
    }
}
