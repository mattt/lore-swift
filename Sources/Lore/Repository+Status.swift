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
    /// A symbolic link.
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

    /// A Boolean value that indicates whether the file is in conflict.
    public var isConflicted: Bool
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
                    isConflicted: Bool(data.flag_conflict)
                )
            )
        default:
            return nil
        }
    }
}
