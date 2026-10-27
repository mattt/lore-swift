import CLore

/// A Lore repository in a local directory.
///
/// A `Repository` value names a directory and the options
/// that operations on it use;
/// creating one doesn't touch the file system.
/// Use ``create(at:name:description:options:)`` to make a new repository
/// or ``clone(from:to:revision:options:)`` to copy one from a server.
///
/// Every operation is an `async` method
/// that runs on the library's own threads
/// and returns when the library reports that the operation has ended.
/// The library can't cancel an operation once it starts,
/// so the methods finish their work even if the calling task is cancelled.
///
/// Paths that you pass to the methods of a repository,
/// such as the paths to ``stage(_:scan:)``,
/// are relative to the repository directory unless they're absolute.
///
/// Methods that take a revision accept the forms
/// that the `lore` command-line tool accepts:
/// a whole hash signature,
/// such as the ``RevisionID/description`` of a revision ID,
/// or `branch@number`, `branch@LATEST`, or `branch@hash`,
/// where an omitted branch means the current branch.
/// A revision identifies its branch,
/// so syncing to a revision on another branch moves onto that branch.
public struct Repository: Sendable, Hashable {
    /// The path of the repository directory.
    public var path: String

    /// The options that the operations on this repository use.
    public var options: Options

    /// Creates a value for the repository in the given directory.
    ///
    /// - Parameters:
    ///   - path: The path of the repository directory.
    ///   - options: The options that operations on the repository use.
    public init(path: String, options: Options = Options()) {
        self.path = path
        self.options = options
    }
}

extension Repository {
    /// Options that apply to every operation on a repository.
    ///
    /// These correspond to fields of `lore_global_args_t`.
    public struct Options: Sendable, Hashable {
        /// The identity that commits record as their author,
        /// such as an email address.
        ///
        /// Lore needs an identity to commit
        /// when the repository configuration doesn't name one
        /// and no authentication token supplies one.
        public var identity: String?

        /// A Boolean value that indicates whether operations
        /// run without connecting to a server.
        public var offline: Bool

        /// The number of parallel storage connections for bulk transfers,
        /// or `nil` for the library's default.
        public var maximumConnections: Int?

        /// Creates options for repository operations.
        ///
        /// - Parameters:
        ///   - identity: The identity that commits record.
        ///   - offline: Whether operations run without connecting to a server.
        ///   - maximumConnections: The number of parallel storage connections.
        public init(
            identity: String? = nil,
            offline: Bool = false,
            maximumConnections: Int? = nil
        ) {
            self.identity = identity
            self.offline = offline
            self.maximumConnections = maximumConnections
        }
    }
}

extension Repository {
    /// Builds the global arguments for an operation on this repository.
    ///
    /// The working directory is the repository directory,
    /// so the library resolves relative paths against it.
    func globals(in arena: Arena) -> UnsafeMutablePointer<lore_global_args_t> {
        let globals = arena.allocate(lore_global_args_t.self)
        globals.pointee.repository_path = arena.string(path)
        globals.pointee.working_directory = arena.string(path)
        globals.pointee.identity = arena.string(options.identity)
        globals.pointee.offline = UInt8(options.offline)
        if let maximumConnections = options.maximumConnections {
            globals.pointee.max_connections = UInt32(clamping: maximumConnections)
        }
        return globals
    }

    /// Starts an operation on this repository and waits for it to end.
    func perform<Arguments, Event: Sendable>(
        _ function: (
            UnsafePointer<lore_global_args_t>?,
            UnsafePointer<Arguments>?,
            lore_event_callback_config_t
        ) -> Void,
        configure: (UnsafeMutablePointer<Arguments>, Arena) -> Void = { _, _ in },
        transform: @escaping EventTransform<Event>
    ) async throws -> [Event] {
        let arena = Arena()
        let globals = globals(in: arena)
        let arguments = arena.allocate(Arguments.self)
        configure(arguments, arena)
        return try await Lore.perform(transform) { callback in
            withExtendedLifetime(arena) {
                function(globals, arguments, callback)
            }
        }
    }

    /// Starts an operation on this repository and returns a stream of its updates.
    func updates<Arguments, Event: Sendable, Progress: Sendable, Result: Sendable>(
        _ function: (
            UnsafePointer<lore_global_args_t>?,
            UnsafePointer<Arguments>?,
            lore_event_callback_config_t
        ) -> Void,
        configure: (UnsafeMutablePointer<Arguments>, Arena) -> Void = { _, _ in },
        transform: @escaping EventTransform<Event>,
        progress: @escaping @Sendable (Event) -> Progress?,
        result: @escaping @Sendable ([Event]) throws -> Result
    ) -> AsyncThrowingStream<OperationUpdate<Progress, Result>, any Error> {
        let arena = Arena()
        let globals = globals(in: arena)
        let arguments = arena.allocate(Arguments.self)
        configure(arguments, arena)
        return Lore.stream(transform, progress: progress, result: result) { callback in
            withExtendedLifetime(arena) {
                function(globals, arguments, callback)
            }
        }
    }
}
