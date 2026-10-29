import CLore
import Foundation

/// A Lore repository in a local directory.
///
/// A `Repository` value names a directory and the options
/// that operations on it use;
/// creating one doesn't touch the file system.
/// Use ``create(at:name:description:store:options:)`` to make a new repository
/// or ``clone(from:to:revision:store:options:)`` to copy one from a server.
///
/// Every operation is an `async` method
/// that runs on the library's own threads
/// and returns when the library reports that the operation has ended.
/// The library can't cancel an operation once it starts,
/// so the methods finish their work even if the calling task is cancelled.
///
/// Paths that you pass to the methods of a repository,
/// such as the paths to ``stage(_:scanning:)``,
/// are relative to the repository directory unless they're absolute.
/// Methods that take a revision take a ``RevisionSpecifier``.
public struct Repository: Sendable, Hashable {
    /// The path of the repository directory.
    ///
    /// Operations resolve a relative path
    /// against the current directory of the process.
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
        public var isOffline: Bool

        /// The number of parallel storage connections for bulk transfers,
        /// or `nil` for the library's default.
        public var maximumConnections: Int?

        /// Creates options for repository operations.
        ///
        /// - Parameters:
        ///   - identity: The identity that commits record.
        ///   - isOffline: Whether operations run without connecting to a server.
        ///   - maximumConnections: The number of parallel storage connections.
        public init(
            identity: String? = nil,
            isOffline: Bool = false,
            maximumConnections: Int? = nil
        ) {
            self.identity = identity
            self.isOffline = isOffline
            self.maximumConnections = maximumConnections
        }
    }
}

extension Repository {
    /// Builds the global arguments for an operation on this repository.
    ///
    /// The working directory is the repository directory,
    /// so the library resolves relative paths against it.
    /// Set `force` for an operation that refuses to discard local changes
    /// unless the library's global `force` flag is set,
    /// and `offline` for an operation that reads only local state
    /// in a repository that isn't offline.
    func globals(
        in arena: Arena,
        force: Bool = false,
        offline: Bool = false
    ) -> UnsafeMutablePointer<lore_global_args_t> {
        let globals = arena.allocate(lore_global_args_t.self)
        globals.pointee.force = UInt8(force)
        // The library resolves a relative repository path
        // against the working directory,
        // so both are absolute.
        let directory = absolutePath
        globals.pointee.repository_path = arena.string(directory)
        globals.pointee.working_directory = arena.string(directory)
        globals.pointee.identity = arena.string(options.identity)
        globals.pointee.offline = UInt8(options.isOffline || offline)
        if let maximumConnections = options.maximumConnections {
            globals.pointee.max_connections = UInt32(clamping: maximumConnections)
        }
        return globals
    }

    /// The path of the repository directory,
    /// resolved against the current directory of the process if it's relative,
    /// or the empty string for an empty path.
    var absolutePath: String {
        Repository.absolutePath(of: path)
    }

    /// Resolves a path against the current directory of the process if it's relative,
    /// returning the empty string for an empty path.
    ///
    /// Paths that the binding passes to the library resolve
    /// against the call's working directory instead,
    /// so the binding resolves the paths
    /// that a caller expects to be relative to the current directory.
    static func absolutePath(of path: String) -> String {
        guard !path.isEmpty else {
            return ""
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// Starts an operation on this repository and waits for it to end.
    func perform<Arguments, Event: Sendable>(
        _ function: (
            UnsafePointer<lore_global_args_t>?,
            UnsafePointer<Arguments>?,
            lore_event_callback_config_t
        ) -> Void,
        force: Bool = false,
        offline: Bool = false,
        configure: (UnsafeMutablePointer<Arguments>, Arena) -> Void = { _, _ in },
        transform: @escaping EventTransform<Event>
    ) async throws -> [Event] {
        let arena = Arena()
        let globals = globals(in: arena, force: force, offline: offline)
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
