import CLore

/// A layer of another repository in this repository's working directory.
///
/// A layer places a directory of another repository at a path
/// in the working directory on this machine only.
/// The revisions of this repository don't record layers,
/// so clones don't have them.
public struct Layer: Sendable, Hashable {
    /// The path where the layer is placed, relative to the repository directory.
    public var path: String

    /// The identifier of the repository that the layer comes from.
    public var repositoryID: RepositoryID

    /// The path of the placed directory in the layer's repository,
    /// or an empty string for its root.
    public var sourcePath: String

    /// The metadata key that selects the layer's revision,
    /// or `nil` if the layer doesn't match revisions by metadata.
    public var metadataKey: String?

    /// The revision of the layer's repository in the working directory.
    public var revision: RevisionID?
}

extension Repository {
    /// Places a directory of another repository in the working directory
    /// as a layer.
    ///
    /// The layer needs a server.
    /// Lore copies the layer's files into the working directory at `path`.
    /// Staging and committing files under `path`
    /// commits them in the layer's repository,
    /// and pushing pushes those revisions to the layer's repository.
    /// The files aren't part of this repository's revisions,
    /// and ``status(of:scanning:)`` doesn't list them.
    ///
    /// The layer uses the branch of its repository
    /// that matches the current branch of this repository,
    /// which Lore creates on the server if it doesn't exist.
    ///
    /// - Parameters:
    ///   - repository: The name or the ``RepositoryID`` of the repository
    ///     on the server of this repository.
    ///   - path: The path to place the layer at, relative to the repository directory.
    ///   - sourcePath: The path of a directory in the layer's repository to place,
    ///     or `nil` for its root.
    ///   - metadataKey: A revision metadata key to select the layer's revision with,
    ///     or `nil` for the latest revision of the layer's branch.
    ///     With a key, the layer uses the revision of its repository
    ///     whose value for the key matches that of the current revision
    ///     of this repository.
    /// - Returns: The layer.
    /// - Throws: ``LoreError`` if the library can't add the layer,
    ///   such as ``LoreError/Code/noRemote`` in an offline repository,
    ///   ``LoreError/Code/notFound`` for a repository that the server doesn't find,
    ///   such as one named by its URL,
    ///   ``LoreError/Code/nodeNotFound`` for a `sourcePath` that doesn't exist,
    ///   or ``LoreError/Code/alreadyLinked``
    ///   if the repository is already a layer at `path`.
    @discardableResult
    public func addLayer(
        from repository: String,
        at path: String,
        sourcePath: String? = nil,
        matchingMetadataKey metadataKey: String? = nil
    ) async throws -> Layer {
        let layers = try await perform(
            lore_layer_add_async,
            configure: { (arguments: UnsafeMutablePointer<lore_layer_add_args_t>, arena) in
                arguments.pointee.target_path = arena.string(path)
                arguments.pointee.source_repository = arena.string(repository)
                arguments.pointee.source_path = arena.string(sourcePath)
                arguments.pointee.metadata = arena.string(metadataKey)
            },
            transform: { event -> Layer? in
                guard event.pointee.tag == LORE_EVENT_LAYER_ADD.rawValue else {
                    return nil
                }
                let data = event.pointee.layer_add
                return Layer(
                    path: data.target_path,
                    repository: data.source_repository,
                    sourcePath: data.source_path,
                    metadataKey: data.metadata,
                    revision: data.revision
                )
            }
        )
        guard let layer = layers.last else {
            throw LoreError.missingEvent("the layer")
        }
        return layer
    }

    /// Removes a layer from the working directory.
    ///
    /// Lore deletes the layer's files from the working directory.
    /// Untracked files under the layer's path stay,
    /// unless `deletingUntrackedFiles` is `true`.
    ///
    /// - Parameters:
    ///   - path: The path where the layer is placed,
    ///     relative to the repository directory.
    ///   - repository: The name or the ``RepositoryID`` of the layer's repository,
    ///     or `nil` if only one layer is placed at `path`.
    ///   - deletingUntrackedFiles: Whether to delete everything under `path`.
    ///   - discardingLocalChanges: Whether to remove the layer
    ///     even if its files have local or staged changes,
    ///     which are lost.
    /// - Throws: ``LoreError`` if the library can't remove the layer,
    ///   such as ``LoreError/Code/layerNotFound``,
    ///   or ``LoreError/Code/localModifications``
    ///   if the layer's files have changes and `discardingLocalChanges` is `false`.
    public func removeLayer(
        at path: String,
        from repository: String? = nil,
        deletingUntrackedFiles: Bool = false,
        discardingLocalChanges: Bool = false
    ) async throws {
        _ = try await perform(
            lore_layer_remove_async,
            force: discardingLocalChanges,
            configure: { (arguments: UnsafeMutablePointer<lore_layer_remove_args_t>, arena) in
                arguments.pointee.target_path = arena.string(path)
                arguments.pointee.source_repository = arena.string(repository)
                arguments.pointee.purge = UInt8(deletingUntrackedFiles)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Lists the layers in the working directory.
    ///
    /// The list works offline.
    ///
    /// - Returns: The layers, in the order that they were added.
    /// - Throws: ``LoreError`` if the library can't list the layers.
    public func layers() async throws -> [Layer] {
        try await perform(
            lore_layer_list_async,
            configure: { (_: UnsafeMutablePointer<lore_layer_list_args_t>, _) in },
            transform: { event -> Layer? in
                guard event.pointee.tag == LORE_EVENT_LAYER_ENTRY.rawValue else {
                    return nil
                }
                let data = event.pointee.layer_entry
                return Layer(
                    path: data.target_path,
                    repository: data.source_repository,
                    sourcePath: data.source_path,
                    metadataKey: data.metadata,
                    revision: data.revision
                )
            }
        )
    }
}

extension Layer {
    /// Copies the fields of a layer event,
    /// returning `nil` if it names no repository.
    fileprivate init?(
        path: lore_string_t,
        repository: lore_partition_t,
        sourcePath: lore_string_t,
        metadataKey: lore_string_t,
        revision: lore_hash_t
    ) {
        guard let repositoryID = RepositoryID(repository) else {
            return nil
        }
        let metadataKey = String(metadataKey)
        self.init(
            path: String(path),
            repositoryID: repositoryID,
            sourcePath: String(sourcePath),
            metadataKey: metadataKey.isEmpty ? nil : metadataKey,
            revision: RevisionID(revision)
        )
    }
}
