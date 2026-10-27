import CLore

/// The progress of a clone.
public struct CloneProgress: Sendable, Hashable {
    /// The number of files cloned.
    public var filesCloned: Int
    /// The total number of files to clone, as discovered so far.
    public var filesToClone: Int
    /// The number of bytes transferred.
    public var bytesTransferred: Int
    /// The total number of bytes to transfer, as discovered so far.
    public var bytesToTransfer: Int
    /// A Boolean value that indicates whether the clone
    /// has discovered every file to clone.
    public var isDiscoveryComplete: Bool

    init(_ data: lore_repository_clone_count_data_t) {
        filesCloned = Int(clamping: data.file_complete)
        filesToClone = Int(clamping: data.file_count)
        bytesTransferred = Int(clamping: data.bytes_transferred)
        bytesToTransfer = Int(clamping: data.bytes_total)
        isDiscoveryComplete = Bool(data.discovery_complete)
    }
}

extension Repository {
    /// Creates a repository in a directory.
    ///
    /// When `options.isOffline` is `true`,
    /// `name` names the repository;
    /// otherwise it's the URL of the repository on a server,
    /// such as `lore://127.0.0.1:41337/my-project`.
    ///
    /// - Parameters:
    ///   - path: The path of the directory for the repository.
    ///   - name: The URL or, offline, the name of the repository.
    ///     An empty name, offline, names the repository after its directory.
    ///   - description: An optional description of the repository.
    ///   - options: The options for operations on the repository.
    /// - Returns: The new repository.
    /// - Throws: ``LoreError`` if the library can't create the repository,
    ///   such as ``LoreError/Code/repositoryAlreadyExists``.
    @discardableResult
    public static func create(
        at path: String,
        name: String = "",
        description: String? = nil,
        options: Options = Options()
    ) async throws -> Repository {
        let repository = Repository(path: path, options: options)
        _ = try await repository.perform(
            lore_repository_create_async,
            configure: { (arguments: UnsafeMutablePointer<lore_repository_create_args_t>, arena) in
                arguments.pointee.repository_url = arena.string(name)
                arguments.pointee.description = arena.string(description)
            },
            transform: { _ -> Never? in nil }
        )
        return repository
    }

    /// Clones a repository from a server into a directory.
    ///
    /// - Parameters:
    ///   - url: The URL of the repository,
    ///     such as `lore://127.0.0.1:41337/my-project`.
    ///   - path: The path of the directory for the clone.
    ///   - revision: The revision to check out,
    ///     or `nil` for the latest revision of the default branch.
    ///   - options: The options for operations on the repository.
    /// - Returns: The cloned repository.
    /// - Throws: ``LoreError`` if the library can't clone the repository.
    @discardableResult
    public static func clone(
        from url: String,
        to path: String,
        revision: RevisionSpecifier? = nil,
        options: Options = Options()
    ) async throws -> Repository {
        let repository = Repository(path: path, options: options)
        _ = try await repository.perform(
            lore_repository_clone_async,
            configure: cloneArguments(url: url, revision: revision),
            transform: { _ -> Never? in nil }
        )
        return repository
    }

    /// Clones a repository from a server into a directory,
    /// reporting its progress.
    ///
    /// The clone starts when you call this method,
    /// whether or not you iterate the stream.
    ///
    /// - Parameters:
    ///   - url: The URL of the repository,
    ///     such as `lore://127.0.0.1:41337/my-project`.
    ///   - path: The path of the directory for the clone.
    ///   - revision: The revision to check out,
    ///     or `nil` for the latest revision of the default branch.
    ///   - options: The options for operations on the repository.
    /// - Returns: A stream of the clone's progress, then the cloned repository.
    ///   The stream throws ``LoreError`` if the clone fails.
    public static func cloneUpdates(
        from url: String,
        to path: String,
        revision: RevisionSpecifier? = nil,
        options: Options = Options()
    ) -> AsyncThrowingStream<OperationUpdate<CloneProgress, Repository>, any Error> {
        let repository = Repository(path: path, options: options)
        return repository.updates(
            lore_repository_clone_async,
            configure: cloneArguments(url: url, revision: revision),
            transform: { event -> CloneProgress? in
                switch event.pointee.tag {
                case LORE_EVENT_REPOSITORY_CLONE_PROGRESS.rawValue:
                    CloneProgress(event.pointee.repository_clone_progress.count)
                case LORE_EVENT_REPOSITORY_CLONE_END.rawValue:
                    CloneProgress(event.pointee.repository_clone_end.count)
                default:
                    nil
                }
            },
            progress: { $0 },
            result: { _ in repository }
        )
    }

    private static func cloneArguments(
        url: String,
        revision: RevisionSpecifier?
    ) -> (UnsafeMutablePointer<lore_repository_clone_args_t>, Arena) -> Void {
        { arguments, arena in
            arguments.pointee.repository_url = arena.string(url)
            arguments.pointee.revision = arena.string(revision?.rawValue)
        }
    }
}
