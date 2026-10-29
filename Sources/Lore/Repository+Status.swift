import CLore

/// The change that an operation applies to a file.
///
/// Corresponds to `lore_file_action_t`.
/// A file whose content changed in place keeps its path,
/// so its action is ``keep``.
public struct FileAction: RawRepresentable, Sendable, Hashable {
    /// The raw value of the action.
    public var rawValue: UInt32

    /// Creates an action from its raw value.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// The file keeps its path.
    public static let keep = Self(rawValue: LORE_FILE_ACTION_KEEP.rawValue)
    /// The file was added.
    public static let add = Self(rawValue: LORE_FILE_ACTION_ADD.rawValue)
    /// The file was deleted.
    public static let delete = Self(rawValue: LORE_FILE_ACTION_DELETE.rawValue)
    /// The file was moved to a new path.
    public static let move = Self(rawValue: LORE_FILE_ACTION_MOVE.rawValue)
    /// The file was copied from another path.
    public static let copy = Self(rawValue: LORE_FILE_ACTION_COPY.rawValue)
}

extension FileAction: CustomStringConvertible {
    public var description: String {
        switch self {
        case .keep: "keep"
        case .add: "add"
        case .delete: "delete"
        case .move: "move"
        case .copy: "copy"
        default: "action \(rawValue)"
        }
    }
}

/// The kind of a node that a repository tracks.
public enum NodeKind: UInt32, Sendable, Hashable {
    /// A directory.
    case directory = 0
    /// A file.
    case file = 1
    /// A link to another repository's tree,
    /// whose contents belong to the linked repository.
    ///
    /// The name comes from the comment on `LORE_NODE_TYPE_LINK`
    /// in the header,
    /// which calls the kind a symbolic link;
    /// the header's revision tree functions treat it as a link to another repository.
    case symbolicLink = 2
}

/// The state of a repository's working directory.
public struct Status: Sendable, Hashable {
    /// The name of the current branch.
    public var branch: String

    /// The identifier of the current branch.
    public var branchID: BranchID?

    /// The current revision,
    /// or `nil` before the first commit.
    public var revision: RevisionID?

    /// The number of the current revision on its branch.
    public var revisionNumber: Int

    /// The latest revision of the branch on the server,
    /// or `nil` if it's unknown.
    public var remoteRevision: RevisionID?

    /// A Boolean value that indicates whether
    /// the local branch has revisions that the server lacks.
    public var isLocalAhead: Bool

    /// A Boolean value that indicates whether
    /// the server has revisions that the local branch lacks.
    public var isRemoteAhead: Bool

    /// A Boolean value that indicates whether
    /// a server is configured and reachable.
    public var isRemoteAvailable: Bool

    /// The files with pending changes, conflicts, or no tracking.
    public var files: [FileStatus]
}

/// The state of one file in a repository's working directory.
public struct FileStatus: Sendable, Hashable {
    /// The path of the file, relative to the repository directory.
    public var path: String

    /// The previous path of a moved or copied file.
    public var previousPath: String?

    /// The size of the file in bytes.
    public var size: Int

    /// The change to the file.
    public var action: FileAction

    /// The kind of node.
    public var kind: NodeKind?

    /// A Boolean value that indicates whether the change is staged.
    public var isStaged: Bool

    /// A Boolean value that indicates whether the file differs
    /// from its recorded state.
    public var isDirty: Bool

    /// A Boolean value that indicates whether the change comes from
    /// the merge, revert, or cherry-pick in progress.
    public var isMerged: Bool

    /// A Boolean value that indicates whether the file has a conflict
    /// that isn't resolved.
    public var isConflicted: Bool

    /// The version of the file that resolves its conflict,
    /// or `nil` if the file has no conflict or its conflict isn't resolved.
    ///
    /// A file that both sides of a merge changed in different places,
    /// and that the library merged automatically,
    /// reports ``MergeSide/merged``.
    public var conflictResolution: MergeSide?
}

extension Repository {
    /// Reports the state of the working directory.
    ///
    /// - Parameters:
    ///   - paths: The paths to check,
    ///     relative to the repository directory.
    ///     Pass an empty array to check every path.
    ///   - scanning: Whether to compare the files on disk
    ///     with the current revision.
    ///     Without a scan,
    ///     the report includes only the files
    ///     that the repository already marks as changed.
    /// - Returns: The state of the working directory.
    /// - Throws: ``LoreError`` if the library can't report the status.
    public func status(of paths: [String] = [], scanning: Bool = true) async throws -> Status {
        let events = try await perform(
            lore_repository_status_async,
            configure: { (arguments: UnsafeMutablePointer<lore_repository_status_args_t>, arena) in
                arguments.pointee.staged = 1
                arguments.pointee.scan = UInt8(scanning)
                arguments.pointee.paths = arena.strings(paths)
            },
            transform: StatusEvent.init
        )
        var status = Status(
            branch: "",
            revisionNumber: 0,
            isLocalAhead: false,
            isRemoteAhead: false,
            isRemoteAvailable: false,
            files: []
        )
        for event in events {
            switch event {
            case .revision(let revision):
                status.branch = revision.branch
                status.branchID = revision.branchID
                status.revision = revision.revision
                status.revisionNumber = revision.revisionNumber
                status.remoteRevision = revision.remoteRevision
                status.isLocalAhead = revision.isLocalAhead
                status.isRemoteAhead = revision.isRemoteAhead
                status.isRemoteAvailable = revision.isRemoteAvailable
            case .file(let file):
                status.files.append(file)
            }
        }
        return status
    }
}

/// An event of a status operation.
private enum StatusEvent: Sendable {
    case revision(Status)
    case file(FileStatus)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_REPOSITORY_STATUS_REVISION.rawValue:
            let data = event.pointee.repository_status_revision
            self = .revision(
                Status(
                    branch: String(data.branch_name),
                    branchID: BranchID(data.branch),
                    revision: RevisionID(data.revision),
                    revisionNumber: Int(clamping: data.revision_number),
                    remoteRevision: RevisionID(data.revision_remote),
                    isLocalAhead: Bool(data.is_local_ahead),
                    isRemoteAhead: Bool(data.is_remote_ahead),
                    isRemoteAvailable: Bool(data.remote_available),
                    files: []
                )
            )
        case LORE_EVENT_REPOSITORY_STATUS_FILE.rawValue:
            let data = event.pointee.repository_status_file
            let previousPath = String(data.from_path)
            self = .file(
                FileStatus(
                    path: String(data.path),
                    previousPath: previousPath.isEmpty ? nil : previousPath,
                    size: Int(clamping: data.size),
                    action: FileAction(rawValue: data.action.rawValue),
                    kind: NodeKind(rawValue: data.type.rawValue),
                    isStaged: Bool(data.flag_staged),
                    isDirty: Bool(data.flag_dirty),
                    isMerged: Bool(data.flag_merged),
                    isConflicted: Bool(data.flag_conflict_unresolved),
                    conflictResolution: MergeSide(data)
                )
            )
        default:
            return nil
        }
    }
}

extension MergeSide {
    /// Reads how a status entry's conflict is resolved,
    /// returning `nil` for no conflict or an unresolved one.
    fileprivate init?(_ data: lore_repository_status_file_event_data_t) {
        guard Bool(data.flag_conflict), !Bool(data.flag_conflict_unresolved) else {
            return nil
        }
        if Bool(data.flag_conflict_mine) {
            self = .mine
        } else if Bool(data.flag_conflict_theirs) {
            self = .theirs
        } else {
            self = .merged
        }
    }
}

/// The parts of the status of a repository
/// that the results of other operations depend on.
struct RepositoryState: Sendable {
    /// The identifier of the repository.
    var repositoryID: RepositoryID

    /// The incoming revision of the merge in progress,
    /// or of an earlier merge that the library still reports.
    var mergedRevision: RevisionID?

    /// The paths of the files with unresolved conflicts.
    var unresolvedPaths: Set<String> = []
}

extension Repository {
    /// Reads the identifier of the repository
    /// and the state of a merge,
    /// without scanning the working directory or connecting to the server.
    ///
    /// Operations on a repository with links or layers
    /// also report events for the linked repositories and layers;
    /// the identifier tells this repository's events apart.
    ///
    /// - Parameter includingFiles: Whether to read the files with unresolved conflicts.
    func state(includingFiles: Bool = false) async throws -> RepositoryState {
        let events = try await perform(
            lore_repository_status_async,
            offline: true,
            configure: { (arguments: UnsafeMutablePointer<lore_repository_status_args_t>, _) in
                arguments.pointee.staged = UInt8(includingFiles)
                arguments.pointee.revision_only = UInt8(!includingFiles)
            },
            transform: { event -> RepositoryStateEvent? in
                switch event.pointee.tag {
                case LORE_EVENT_REPOSITORY_STATUS_REVISION.rawValue:
                    let data = event.pointee.repository_status_revision
                    guard let repositoryID = RepositoryID(data.repository) else {
                        return nil
                    }
                    return .repository(repositoryID, mergedRevision: RevisionID(data.revision_merged))
                case LORE_EVENT_REPOSITORY_STATUS_FILE.rawValue:
                    let data = event.pointee.repository_status_file
                    return Bool(data.flag_conflict_unresolved) ? .unresolved(String(data.path)) : nil
                default:
                    return nil
                }
            }
        )
        var state: RepositoryState?
        var unresolvedPaths: Set<String> = []
        for event in events {
            switch event {
            case .repository(let repositoryID, let mergedRevision):
                state = RepositoryState(repositoryID: repositoryID, mergedRevision: mergedRevision)
            case .unresolved(let path):
                unresolvedPaths.insert(path)
            }
        }
        guard var state else {
            throw LoreError.missingEvent("the repository")
        }
        state.unresolvedPaths = unresolvedPaths
        return state
    }
}

/// An event of a status operation that ``Repository/state(includingFiles:)`` reads.
private enum RepositoryStateEvent: Sendable {
    case repository(RepositoryID, mergedRevision: RevisionID?)
    case unresolved(String)
}
