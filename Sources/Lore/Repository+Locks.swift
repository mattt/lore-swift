import CLore

/// A lock on a file, held on the server.
public struct FileLock: Sendable, Hashable {
    /// The path of the locked file, relative to the repository directory.
    public var path: String

    /// The identifier of the user who holds the lock.
    public var owner: String

    /// The time the lock was acquired, as the library reports it.
    public var timestamp: UInt64

    /// The branch that the lock belongs to,
    /// when the library reports it.
    public var branchID: BranchID?
}

/// The result of a request to lock files.
public struct LockResult: Sendable, Hashable {
    /// The paths that the request locked.
    public var acquired: [String]

    /// The paths that the caller already held locks on.
    public var alreadyOwned: [String]
}

extension Repository {
    /// Locks files on a branch,
    /// so that other users can't lock them until you unlock them.
    ///
    /// Locks are held on the server,
    /// so the repository must not be offline.
    ///
    /// - Parameters:
    ///   - paths: The paths of the files, relative to the repository directory.
    ///   - branch: The name of the branch, or `nil` for the current branch.
    /// - Returns: The paths that the request locked
    ///   and those that the caller already held.
    /// - Throws: ``LoreError`` if the library can't lock the files,
    ///   such as ``LoreError/Code/lockNotOwned``
    ///   when another user holds a lock.
    @discardableResult
    public func lock(_ paths: [String], branch: String? = nil) async throws -> LockResult {
        let events = try await perform(
            lore_lock_file_acquire_async,
            configure: { (arguments: UnsafeMutablePointer<lore_lock_file_acquire_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
                arguments.pointee.branch = arena.string(branch)
            },
            transform: { event -> LockEvent? in
                switch event.pointee.tag {
                case LORE_EVENT_LOCK_FILE_ACQUIRE_BEGIN.rawValue:
                    .begin(alreadyOwned: Bool(event.pointee.lock_file_acquire_begin.ignored))
                case LORE_EVENT_LOCK_FILE_ACQUIRE.rawValue:
                    .path(String(event.pointee.lock_file_acquire.path))
                default:
                    nil
                }
            }
        )
        // Each ACQUIRE_BEGIN event says whether the entries that follow it
        // were acquired or already owned.
        var result = LockResult(acquired: [], alreadyOwned: [])
        var alreadyOwned = false
        for event in events {
            switch event {
            case .begin(let ignored):
                alreadyOwned = ignored
            case .path(let path) where alreadyOwned:
                result.alreadyOwned.append(path)
            case .path(let path):
                result.acquired.append(path)
            }
        }
        return result
    }

    /// Releases locks on files.
    ///
    /// - Parameters:
    ///   - paths: The paths of the files, relative to the repository directory.
    ///   - branch: The name of the branch, or `nil` for the current branch.
    /// - Returns: The paths whose locks were released.
    /// - Throws: ``LoreError`` if the library can't release the locks.
    @discardableResult
    public func unlock(_ paths: [String], branch: String? = nil) async throws -> [String] {
        let events = try await perform(
            lore_lock_file_release_async,
            configure: { (arguments: UnsafeMutablePointer<lore_lock_file_release_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
                arguments.pointee.branch = arena.string(branch)
            },
            transform: { event -> LockEvent? in
                switch event.pointee.tag {
                case LORE_EVENT_LOCK_FILE_RELEASE_BEGIN.rawValue:
                    .begin(alreadyOwned: Bool(event.pointee.lock_file_release_begin.not_found))
                case LORE_EVENT_LOCK_FILE_RELEASE.rawValue:
                    .path(String(event.pointee.lock_file_release.path))
                default:
                    nil
                }
            }
        )
        // A RELEASE_BEGIN event with `not_found` set introduces
        // the paths that had no lock to release.
        var released: [String] = []
        var notFound = false
        for event in events {
            switch event {
            case .begin(let flag):
                notFound = flag
            case .path(let path) where !notFound:
                released.append(path)
            case .path:
                break
            }
        }
        return released
    }

    /// Returns the locks on files.
    ///
    /// - Parameters:
    ///   - paths: The paths of the files, relative to the repository directory.
    ///   - branch: The name of the branch, or `nil` for the current branch.
    /// - Returns: The locks on the files that are locked.
    /// - Throws: ``LoreError`` if the library can't read the locks.
    public func locks(on paths: [String], branch: String? = nil) async throws -> [FileLock] {
        try await perform(
            lore_lock_file_status_async,
            configure: { (arguments: UnsafeMutablePointer<lore_lock_file_status_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
                arguments.pointee.branch = arena.string(branch)
            },
            transform: { event -> FileLock? in
                guard event.pointee.tag == LORE_EVENT_LOCK_FILE_STATUS.rawValue else {
                    return nil
                }
                let data = event.pointee.lock_file_status
                return FileLock(
                    path: String(data.path),
                    owner: String(data.owner),
                    timestamp: data.locked_at
                )
            }
        )
    }

    /// Returns the locks on a branch,
    /// optionally only those of one owner or on one path.
    ///
    /// - Parameters:
    ///   - branch: The name of the branch, or `nil` for the current branch.
    ///   - owner: The owner to match, or `nil` for any owner.
    ///   - path: The path to match, or `nil` for any path.
    /// - Returns: The matching locks.
    /// - Throws: ``LoreError`` if the library can't query the locks.
    public func locks(
        branch: String? = nil,
        owner: String? = nil,
        path: String? = nil
    ) async throws -> [FileLock] {
        try await perform(
            lore_lock_file_query_async,
            configure: { (arguments: UnsafeMutablePointer<lore_lock_file_query_args_t>, arena) in
                arguments.pointee.branch = arena.string(branch)
                arguments.pointee.owner = arena.string(owner)
                arguments.pointee.path = arena.string(path)
            },
            transform: { event -> FileLock? in
                guard event.pointee.tag == LORE_EVENT_LOCK_FILE_QUERY.rawValue else {
                    return nil
                }
                let data = event.pointee.lock_file_query
                return FileLock(
                    path: String(data.path),
                    owner: String(data.owner),
                    timestamp: data.locked_at,
                    branchID: BranchID(data.branch)
                )
            }
        )
    }
}

/// An event of a lock acquisition or release.
private enum LockEvent: Sendable {
    case begin(alreadyOwned: Bool)
    case path(String)
}
