import CLore

/// The result of a push.
public struct PushResult: Sendable, Hashable {
    /// The URL of the server.
    public var remote: String

    /// The name of the branch that was pushed.
    public var branch: String

    /// The latest revision of the branch on the server after the push,
    /// or `nil` if the push sent no revision.
    public var revision: RevisionID?

    /// The number of the latest revision on the server after the push.
    public var revisionNumber: UInt64?

    /// The number of local revisions that the push sent.
    public var revisionCount: UInt64

    /// A Boolean value that indicates whether the server
    /// already had the local revision.
    public var wasAlreadyPushed: Bool
}

/// The progress of a push.
public struct PushProgress: Sendable, Hashable {
    /// The number of fragments transferred.
    public var fragmentsTransferred: UInt64
    /// The number of fragments to transfer.
    public var fragmentCount: UInt64
    /// The number of bytes transferred.
    public var bytesTransferred: UInt64
    /// The number of bytes to transfer.
    public var bytesTotal: UInt64
}

/// The result of a sync.
public struct SyncResult: Sendable, Hashable {
    /// The revision that the working directory holds after the sync.
    public var revision: RevisionID?

    /// The number of the revision,
    /// or 0 if the sync staged a merge.
    public var revisionNumber: UInt64

    /// A Boolean value that indicates whether
    /// the sync staged a merge revision.
    public var isMerge: Bool

    /// A Boolean value that indicates whether
    /// the staged merge has conflicts.
    public var hasConflicts: Bool
}

/// The progress of a sync.
public struct SyncProgress: Sendable, Hashable {
    /// The number of files updated.
    public var filesUpdated: Int
    /// The number of files to update.
    public var filesToUpdate: Int
    /// The number of files deleted.
    public var filesDeleted: Int
    /// The number of files to delete.
    public var filesToDelete: Int
    /// The number of bytes written.
    public var bytesUpdated: UInt64
    /// The number of bytes to write.
    public var bytesToUpdate: UInt64
    /// A Boolean value that indicates whether the sync
    /// has discovered all of its work.
    public var isDiscoveryComplete: Bool
}

extension Repository {
    /// Pushes a branch and its new revisions to the server.
    ///
    /// - Parameters:
    ///   - branch: The name of the branch to push,
    ///     or `nil` for the current branch.
    ///   - fastForward: Whether the server may fast-forward merge
    ///     if the branch on the server has moved.
    /// - Returns: The result of the push.
    /// - Throws: ``LoreError`` if the library can't push the branch.
    @discardableResult
    public func push(branch: String? = nil, fastForward: Bool = false) async throws -> PushResult {
        PushEvent.result(
            try await perform(
                lore_branch_push_async,
                configure: pushArguments(branch: branch, fastForward: fastForward),
                transform: PushEvent.init
            )
        )
    }

    /// Pushes a branch and its new revisions to the server,
    /// reporting its progress.
    ///
    /// The push starts when you call this method,
    /// whether or not you iterate the stream.
    ///
    /// - Parameters:
    ///   - branch: The name of the branch to push,
    ///     or `nil` for the current branch.
    ///   - fastForward: Whether the server may fast-forward merge
    ///     if the branch on the server has moved.
    /// - Returns: A stream of the push's progress, then its result.
    ///   The stream throws ``LoreError`` if the push fails.
    public func pushUpdates(
        branch: String? = nil,
        fastForward: Bool = false
    ) -> AsyncThrowingStream<OperationUpdate<PushProgress, PushResult>, any Error> {
        updates(
            lore_branch_push_async,
            configure: pushArguments(branch: branch, fastForward: fastForward),
            transform: PushEvent.init,
            progress: { event in
                if case .progress(let progress) = event { progress } else { nil }
            },
            result: PushEvent.result
        )
    }

    private func pushArguments(
        branch: String?,
        fastForward: Bool
    ) -> (UnsafeMutablePointer<lore_branch_push_args_t>, Arena) -> Void {
        { arguments, arena in
            arguments.pointee.branch = arena.string(branch)
            arguments.pointee.fast_forward_merge = UInt8(fastForward)
        }
    }

    /// Updates the working directory to a revision,
    /// by default the latest revision of the current branch.
    ///
    /// Syncing fetches the revision from the server unless
    /// the repository is offline.
    ///
    /// - Parameters:
    ///   - revision: The revision to sync to,
    ///     or `nil` for the latest revision of the current branch.
    ///   - discardingLocalChanges: Whether to replace local changes
    ///     with the content of the revision.
    /// - Returns: The result of the sync.
    /// - Throws: ``LoreError`` if the library can't sync,
    ///   such as ``LoreError/Code/localModifications``.
    @discardableResult
    public func sync(
        to revision: String? = nil,
        discardingLocalChanges: Bool = false
    ) async throws -> SyncResult {
        try SyncEvent.result(
            try await perform(
                lore_revision_sync_async,
                configure: syncArguments(revision: revision, reset: discardingLocalChanges),
                transform: SyncEvent.init
            )
        )
    }

    /// Updates the working directory to a revision,
    /// reporting its progress.
    ///
    /// The sync starts when you call this method,
    /// whether or not you iterate the stream.
    ///
    /// - Parameters:
    ///   - revision: The revision to sync to,
    ///     or `nil` for the latest revision of the current branch.
    ///   - discardingLocalChanges: Whether to replace local changes
    ///     with the content of the revision.
    /// - Returns: A stream of the sync's progress, then its result.
    ///   The stream throws ``LoreError`` if the sync fails.
    public func syncUpdates(
        to revision: String? = nil,
        discardingLocalChanges: Bool = false
    ) -> AsyncThrowingStream<OperationUpdate<SyncProgress, SyncResult>, any Error> {
        updates(
            lore_revision_sync_async,
            configure: syncArguments(revision: revision, reset: discardingLocalChanges),
            transform: SyncEvent.init,
            progress: { event in
                if case .progress(let progress) = event { progress } else { nil }
            },
            result: SyncEvent.result
        )
    }

    private func syncArguments(
        revision: String?,
        reset: Bool
    ) -> (UnsafeMutablePointer<lore_revision_sync_args_t>, Arena) -> Void {
        { arguments, arena in
            arguments.pointee.revision = arena.string(revision)
            arguments.pointee.reset = UInt8(reset)
        }
    }
}

/// An event of a push.
private enum PushEvent: Sendable {
    case begin(remote: String, branch: String, revisionCount: UInt64, wasAlreadyPushed: Bool)
    case progress(PushProgress)
    case revisionPushed(RevisionID?, number: UInt64)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_BRANCH_PUSH.rawValue:
            let data = event.pointee.branch_push
            // A linked repository or layer reports its own push event;
            // the result describes the repository itself.
            guard !Bool(data.flag_link), !Bool(data.flag_layer) else {
                return nil
            }
            self = .begin(
                remote: String(data.remote),
                branch: String(data.branch_name),
                revisionCount: data.local_history,
                wasAlreadyPushed: Bool(data.flag_already_pushed)
            )
        case LORE_EVENT_BRANCH_PUSH_FRAGMENT_PROGRESS.rawValue:
            let data = event.pointee.branch_push_fragment_progress
            self = .progress(
                PushProgress(
                    fragmentsTransferred: data.complete,
                    fragmentCount: data.count,
                    bytesTransferred: data.bytes_transferred,
                    bytesTotal: data.bytes_total
                )
            )
        case LORE_EVENT_BRANCH_PUSH_REVISION_PUSH_END.rawValue:
            let data = event.pointee.branch_push_revision_push_end
            self = .revisionPushed(
                RevisionID(data.new_remote_revision),
                number: data.new_remote_revision_number
            )
        default:
            return nil
        }
    }

    @Sendable static func result(_ events: [PushEvent]) -> PushResult {
        var result = PushResult(
            remote: "",
            branch: "",
            revisionCount: 0,
            wasAlreadyPushed: false
        )
        for event in events {
            switch event {
            case .begin(let remote, let branch, let revisionCount, let wasAlreadyPushed):
                result.remote = remote
                result.branch = branch
                result.revisionCount = revisionCount
                result.wasAlreadyPushed = wasAlreadyPushed
            case .revisionPushed(let revision, let number):
                result.revision = revision
                result.revisionNumber = number
            case .progress:
                break
            }
        }
        return result
    }
}

/// An event of a sync.
private enum SyncEvent: Sendable {
    case target(SyncResult)
    case progress(SyncProgress)
    case revision(SyncResult)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_REVISION_SYNC_TARGET.rawValue:
            let data = event.pointee.revision_sync_target
            self = .target(
                SyncResult(
                    revision: RevisionID(data.target_revision),
                    revisionNumber: data.target_revision_number,
                    isMerge: false,
                    hasConflicts: false
                )
            )
        case LORE_EVENT_REVISION_SYNC_PROGRESS.rawValue:
            let data = event.pointee.revision_sync_progress
            self = .progress(
                SyncProgress(
                    filesUpdated: Int(data.file_update),
                    filesToUpdate: Int(data.file_update_total),
                    filesDeleted: Int(data.file_delete),
                    filesToDelete: Int(data.file_delete_total),
                    bytesUpdated: data.bytes_update,
                    bytesToUpdate: data.bytes_update_total,
                    isDiscoveryComplete: Bool(data.discovery_complete)
                )
            )
        case LORE_EVENT_REVISION_SYNC_REVISION.rawValue:
            let data = event.pointee.revision_sync_revision
            self = .revision(
                SyncResult(
                    revision: RevisionID(data.revision),
                    revisionNumber: data.revision_number,
                    isMerge: Bool(data.flag_merge),
                    hasConflicts: Bool(data.flag_conflict)
                )
            )
        default:
            return nil
        }
    }

    @Sendable static func result(_ events: [SyncEvent]) throws -> SyncResult {
        for case .revision(let result) in events.reversed() {
            return result
        }
        // A sync to the revision that the working directory already holds
        // reports its target and no resulting revision.
        for case .target(let result) in events.reversed() {
            return result
        }
        throw LoreError.missingEvent("a revision")
    }
}
