import CLore

/// A version of a file in a merge.
public enum MergeSide: Sendable, Hashable {
    /// The merged content.
    ///
    /// For a merge in progress,
    /// it's the file in the working directory,
    /// which holds conflict markers until you edit it.
    case merged

    /// The version from the current branch.
    case mine

    /// The incoming version,
    /// such as the version from the branch being merged.
    case theirs
}

/// The result of a merge, a revert, or a cherry-pick.
public struct MergeResult: Sendable, Hashable {
    /// The revision that the operation applied:
    /// the latest revision of the merged branch,
    /// or the revision that was reverted or cherry-picked.
    ///
    /// It's `nil` if a merge stopped at a conflict in a linked repository
    /// before it merged this repository;
    /// see ``Repository/mergeBranch(named:message:committing:linkMessages:includingLinks:)``
    /// for what to do next.
    public var sourceRevision: RevisionID?

    /// The revision that the operation committed,
    /// or `nil` if it left its changes staged
    /// because a file is in conflict or `committing` was `false`.
    public var revision: Revision?

    /// The paths of the files left in conflict,
    /// relative to the repository directory,
    /// including files in linked repositories.
    public var conflicts: [String]
}

/// The changes and conflicts that a merge of one branch into another would have.
public struct BranchDiff: Sendable, Hashable {
    /// A change to a file in a branch diff.
    public struct Change: Sendable, Hashable {
        /// The path of the file, relative to the repository directory.
        public var path: String

        /// The previous path of a moved or copied file.
        public var previousPath: String?

        /// The change to the file.
        public var action: FileAction

        /// A Boolean value that indicates whether the library merged
        /// the changes from both branches to the file.
        public var isAutomaticallyMerged: Bool
    }

    /// Changes to the same file in both branches that conflict.
    public struct Conflict: Sendable, Hashable {
        /// The change in the source branch.
        public var source: Change

        /// The change in the target branch.
        public var target: Change
    }

    /// The latest revision of the source branch.
    public var sourceRevision: RevisionID?

    /// The latest revision of the target branch.
    public var targetRevision: RevisionID?

    /// The last revision that both branches share,
    /// which the comparison treats as the base of each side.
    public var baseRevision: RevisionID?

    /// The changes in the source branch
    /// that a merge would apply to the target branch without conflict.
    public var changes: [Change]

    /// The conflicts between the branches.
    public var conflicts: [Conflict]
}

extension Repository {
    /// Compares two branches
    /// as a merge of the source branch into the target branch would.
    ///
    /// With `mergingAutomatically` set to `true`,
    /// the conflicts are those that
    /// ``mergeBranch(named:message:committing:linkMessages:includingLinks:)`` reports
    /// when it merges `source` into `target`.
    ///
    /// - Parameters:
    ///   - source: The name of the branch to merge from.
    ///   - target: The name of the branch to merge into.
    ///   - path: A path to limit the comparison to,
    ///     relative to the repository directory,
    ///     or `nil` to compare every path.
    ///   - mergingAutomatically: Whether to merge the changes to a file
    ///     that both branches changed in different places,
    ///     as a merge does,
    ///     reporting the file as a change instead of a conflict.
    /// - Returns: The changes and conflicts between the branches.
    /// - Throws: ``LoreError`` if the library can't compare the branches,
    ///   such as ``LoreError/Code/branchNotFound``.
    public func branchDiff(
        merging source: String,
        into target: String,
        path: String? = nil,
        mergingAutomatically: Bool = true
    ) async throws -> BranchDiff {
        let events = try await perform(
            lore_branch_diff_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_diff_args_t>, arena) in
                arguments.pointee.source = arena.string(source)
                arguments.pointee.target = arena.string(target)
                arguments.pointee.path = arena.string(path)
                arguments.pointee.auto_resolve = UInt8(mergingAutomatically)
            },
            transform: BranchDiffEvent.init
        )
        var diff = BranchDiff(changes: [], conflicts: [])
        for event in events {
            switch event {
            case .begin(let source, let target, let base):
                diff.sourceRevision = source
                diff.targetRevision = target
                diff.baseRevision = base
            case .change(let change):
                diff.changes.append(change)
            case .conflict(let conflict):
                diff.conflicts.append(conflict)
            }
        }
        return diff
    }

    /// Merges another branch into the current branch.
    ///
    /// The merge stages the changes from the latest revision of the branch,
    /// which comes from the server if the server has newer revisions
    /// and the repository isn't offline.
    /// If no file is in conflict and `committing` is `true`,
    /// the merge commits a revision whose parents are the current revision
    /// and the merged revision.
    /// Otherwise the merge stays in progress until you ``commit(message:linkMessages:)``
    /// or ``abortMerge()``.
    ///
    /// For each file in conflict,
    /// the merge writes the file with conflict markers
    /// and writes each version next to it,
    /// in files whose names end with `~base`, `~mine`, and `~theirs`.
    /// Resolve the conflicts with ``resolveConflicts(in:keeping:)``
    /// before you commit.
    ///
    /// The merge also merges the matching branch
    /// of each linked repository that follows this repository's branches,
    /// and a merge revision that it commits there
    /// has the message for the link in `linkMessages`.
    ///
    /// A conflict in a linked repository stops the merge
    /// before it merges this repository,
    /// and the result's ``MergeResult/sourceRevision`` is `nil`.
    /// After you resolve the conflict,
    /// ``commit(message:linkMessages:)`` commits the merge in the linked repository
    /// and a revision of this repository with one parent that pins the link.
    /// Then call this method again to merge this repository.
    ///
    /// - Parameters:
    ///   - name: The name of the branch to merge.
    ///   - message: The commit message for the merge revision
    ///     if the merge commits,
    ///     or `nil` for an empty message.
    ///   - committing: Whether to commit the merge when no file is in conflict.
    ///   - linkMessages: Commit messages for the merge revisions
    ///     of linked repositories,
    ///     by the path where each link is mounted.
    ///   - includingLinks: Whether to merge linked repositories.
    ///     If `false`, each link keeps the revision that it's pinned to.
    /// - Returns: The result of the merge.
    /// - Throws: ``LoreError`` if the library can't merge,
    ///   such as ``LoreError/Code/branchNotFound``.
    ///   The library refuses to start a merge while you have staged changes
    ///   or another merge is in progress,
    ///   and reports that with ``LoreError/Code/internal``.
    @discardableResult
    public func mergeBranch(
        named name: String,
        message: String? = nil,
        committing: Bool = true,
        linkMessages: [String: String] = [:],
        includingLinks: Bool = true
    ) async throws -> MergeResult {
        try await mergeResult(
            isBranchMerge: true,
            try await perform(
                lore_branch_merge_start_async,
                configure: { (arguments: UnsafeMutablePointer<lore_branch_merge_start_args_t>, arena) in
                    arguments.pointee.branch = arena.string(name)
                    arguments.pointee.message = arena.string(message)
                    arguments.pointee.no_commit = UInt8(!committing)
                    arguments.pointee.ignore_links = UInt8(!includingLinks)
                    let links = linkMessages.sorted { $0.key < $1.key }
                    arguments.pointee.link_paths = arena.strings(links.map(\.key))
                    arguments.pointee.link_messages = arena.strings(links.map(\.value))
                },
                transform: MergeEvent.init
            )
        )
    }

    /// Merges the current branch into another branch,
    /// committing the merge revision on the server.
    ///
    /// The merge needs a server.
    /// The current branch must have been created from another branch,
    /// and it must include the latest revision of the target branch on the server:
    /// if the target branch has moved on,
    /// merge it into the current branch with
    /// ``mergeBranch(named:message:committing:linkMessages:includingLinks:)``
    /// and commit first.
    /// The working directory stays on the current branch.
    ///
    /// - Parameters:
    ///   - target: The name of the branch to merge into.
    ///   - message: The commit message for the merge revision.
    /// - Returns: The merge revision on the target branch, with its metadata.
    /// - Throws: ``LoreError`` if the library can't merge,
    ///   such as ``LoreError/Code/branchNotFound``.
    ///   Lore 0.12.0 reports a target branch with newer revisions
    ///   and an offline repository
    ///   with ``LoreError/Code/internal``.
    @discardableResult
    public func mergeBranch(into target: String, message: String) async throws -> Revision {
        let revisions = try await perform(
            lore_branch_merge_into_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_merge_into_args_t>, arena) in
                arguments.pointee.branch = arena.string(target)
                arguments.pointee.message = arena.string(message)
            },
            transform: { event -> RevisionID? in
                guard event.pointee.tag == LORE_EVENT_BRANCH_MERGE_INTO_REVISION.rawValue else {
                    return nil
                }
                return RevisionID(event.pointee.branch_merge_into_revision.revision)
            }
        )
        guard let id = revisions.last else {
            throw LoreError.missingEvent("a revision")
        }
        // The merge reports the new revision's hash and number,
        // but not its parents or metadata.
        return try await revision(.id(id))
    }

    /// Applies the inverse of a revision's changes to the current revision.
    ///
    /// A revert works like a merge:
    /// if no file is in conflict and `committing` is `true`,
    /// it commits a revision whose `reverted-from` metadata value
    /// is the hash of the reverted revision.
    /// Otherwise the revert stays in progress
    /// until you ``commit(message:linkMessages:)`` or ``abortMerge()``,
    /// and you resolve its conflicts
    /// with ``resolveConflicts(in:keeping:)``,
    /// where ``MergeSide/theirs`` is the reverted version of a file.
    ///
    /// - Parameters:
    ///   - revision: The revision to revert.
    ///   - message: The commit message for the new revision
    ///     if the revert commits,
    ///     or `nil` for an empty message.
    ///   - committing: Whether to commit the revert when no file is in conflict.
    /// - Returns: The result of the revert.
    /// - Throws: ``LoreError`` if the library can't revert,
    ///   such as ``LoreError/Code/revisionNotFound``.
    ///   The library refuses to start a revert while you have staged changes
    ///   or another merge is in progress,
    ///   and reports that with ``LoreError/Code/internal``.
    @discardableResult
    public func revert(
        _ revision: RevisionSpecifier,
        message: String? = nil,
        committing: Bool = true
    ) async throws -> MergeResult {
        try await mergeResult(
            isBranchMerge: false,
            try await perform(
                lore_revision_revert_async,
                configure: { (arguments: UnsafeMutablePointer<lore_revision_revert_args_t>, arena) in
                    arguments.pointee.revision = arena.string(revision.rawValue)
                    arguments.pointee.message = arena.string(message)
                    arguments.pointee.no_commit = UInt8(!committing)
                },
                transform: MergeEvent.init
            )
        )
    }

    /// Applies the changes that a revision made to its parent
    /// to the current revision.
    ///
    /// If no file is in conflict and `committing` is `true`,
    /// the cherry-pick commits a revision with one parent
    /// whose `cherry-picked-from` metadata value
    /// is the hash of the picked revision.
    /// A cherry-pick without conflicts and with `committing` set to `false`
    /// stays in progress until you ``commit(message:linkMessages:)``,
    /// which records the same `cherry-picked-from` value.
    ///
    /// Lore 0.12.0 has no functions to resolve or abort a cherry-pick:
    /// ``resolveConflicts(in:keeping:)`` and ``abortMerge()``
    /// throw ``LoreError/Code/internal`` for one.
    /// To discard a cherry-pick that conflicts,
    /// call ``sync(to:discardingLocalChanges:)``
    /// with `discardingLocalChanges` set to `true`,
    /// which leaves the files that end with `~base`, `~mine`, and `~theirs`.
    ///
    /// - Parameters:
    ///   - revision: The revision to cherry-pick.
    ///   - message: The commit message for the new revision
    ///     if the cherry-pick commits,
    ///     or `nil` for the message of the picked revision.
    ///   - committing: Whether to commit the cherry-pick when no file is in conflict.
    /// - Returns: The result of the cherry-pick.
    /// - Throws: ``LoreError`` if the library can't cherry-pick,
    ///   such as ``LoreError/Code/revisionNotFound``.
    ///   The library refuses to cherry-pick the current revision,
    ///   or to start while you have staged changes or a merge is in progress,
    ///   and reports that with ``LoreError/Code/internal``.
    @discardableResult
    public func cherryPick(
        _ revision: RevisionSpecifier,
        message: String? = nil,
        committing: Bool = true
    ) async throws -> MergeResult {
        try await mergeResult(
            isBranchMerge: false,
            try await perform(
                lore_revision_cherry_pick_async,
                configure: { (arguments: UnsafeMutablePointer<lore_revision_cherry_pick_args_t>, arena) in
                    arguments.pointee.revision = arena.string(revision.rawValue)
                    arguments.pointee.message = arena.string(message)
                    arguments.pointee.no_commit = UInt8(!committing)
                },
                transform: MergeEvent.init
            )
        )
    }

    /// Marks files in conflict as resolved
    /// in the merge or revert in progress.
    ///
    /// Resolving a file with ``MergeSide/merged``
    /// keeps the file in the working directory,
    /// which must no longer contain conflict markers;
    /// the library skips a file that still does.
    /// Resolving a file with ``MergeSide/mine`` or ``MergeSide/theirs``
    /// replaces it in the working directory with that version.
    /// ``FileStatus/conflictResolution`` reports how a file was resolved.
    ///
    /// In a merge that ``sync(to:discardingLocalChanges:)`` stages,
    /// Lore 0.12.0 resolves ``MergeSide/mine``
    /// with the version from the server
    /// and ``MergeSide/theirs`` with your local version,
    /// the reverse of the files that end with `~mine` and `~theirs`.
    /// Lore 0.12.0 can't resolve the conflicts of a cherry-pick.
    ///
    /// A directory path with ``MergeSide/merged`` resolves the files under it.
    /// A directory path with ``MergeSide/mine`` or ``MergeSide/theirs``
    /// replaces every file under it that the operation changed,
    /// including files without conflicts,
    /// and Lore 0.12.0 then reports some of the files without conflicts,
    /// such as files that the merge added, as in conflict.
    /// To keep a side for only the files in conflict,
    /// pass ``MergeResult/conflicts``.
    ///
    /// - Parameters:
    ///   - paths: The paths of the files, relative to the repository directory.
    ///     Pass `["."]` with ``MergeSide/merged`` to resolve every file.
    ///   - side: The version of each file that resolves its conflict.
    /// - Returns: The paths of the files that the call resolved or replaced.
    ///   After a directory path with ``MergeSide/mine`` or ``MergeSide/theirs``,
    ///   the paths can include files that Lore 0.12.0 then reports as in conflict.
    /// - Throws: ``LoreError`` if the library can't resolve the files.
    ///   Lore 0.12.0 reports that no merge is in progress
    ///   with ``LoreError/Code/internal``.
    @discardableResult
    public func resolveConflicts(in paths: [String], keeping side: MergeSide = .merged) async throws -> [String] {
        switch side {
        case .merged:
            try await mergeOrRevert(
                merge: { try await conflictPaths(lore_branch_merge_resolve_async, \.paths, paths) },
                revert: { try await conflictPaths(lore_revision_revert_resolve_async, \.paths, paths) }
            )
        case .mine:
            try await mergeOrRevert(
                merge: { try await conflictPaths(lore_branch_merge_resolve_mine_async, \.paths, paths) },
                revert: { try await conflictPaths(lore_revision_revert_resolve_mine_async, \.paths, paths) }
            )
        case .theirs:
            try await mergeOrRevert(
                merge: { try await conflictPaths(lore_branch_merge_resolve_theirs_async, \.paths, paths) },
                revert: { try await conflictPaths(lore_revision_revert_resolve_theirs_async, \.paths, paths) }
            )
        }
    }

    /// Marks resolved files as in conflict again
    /// in the merge or revert in progress.
    ///
    /// Unresolving a file doesn't change it in the working directory;
    /// call ``restartMerge(of:)`` to write its conflict markers again.
    /// Lore 0.12.0 can't unresolve a file in a linked repository
    /// and throws ``LoreError/Code/internal``.
    ///
    /// - Parameter paths: The paths of the files, relative to the repository directory.
    ///   Lore 0.12.0 ignores directories.
    /// - Returns: The paths of the files that were marked as in conflict.
    /// - Throws: ``LoreError`` if the library can't unresolve the files.
    @discardableResult
    public func unresolveConflicts(in paths: [String]) async throws -> [String] {
        try await mergeOrRevert(
            merge: { try await conflictPaths(lore_branch_merge_unresolve_async, \.paths, paths) },
            revert: { try await conflictPaths(lore_revision_revert_unresolve_async, \.paths, paths) }
        )
    }

    /// Restarts the resolution of files
    /// in the merge or revert in progress.
    ///
    /// Restarting writes each file with conflict markers again
    /// and marks it as in conflict,
    /// discarding its content in the working directory.
    /// Lore 0.12.0 can't restart a file in a linked repository
    /// and throws ``LoreError/Code/invalidArguments``.
    ///
    /// - Parameter paths: The paths of the files, relative to the repository directory.
    ///   Lore 0.12.0 ignores directories.
    /// - Throws: ``LoreError`` if the library can't restart the files.
    public func restartMerge(of paths: [String]) async throws {
        _ = try await mergeOrRevert(
            merge: { try await conflictPaths(lore_branch_merge_restart_async, \.paths, paths) },
            revert: { try await conflictPaths(lore_revision_revert_restart_async, \.paths, paths) }
        )
    }

    /// Abandons the merge or revert in progress,
    /// undoing the changes that it made to the working directory.
    ///
    /// Aborting returns the files that the merge changed
    /// to their content in the current revision,
    /// removes the files that the merge wrote for conflicts,
    /// and keeps changes to files that the merge didn't touch.
    ///
    /// Lore 0.12.0 can't abort a cherry-pick;
    /// call ``sync(to:discardingLocalChanges:)``
    /// with `discardingLocalChanges` set to `true` to discard one.
    ///
    /// - Throws: ``LoreError`` if the library can't abort.
    ///   Lore 0.12.0 reports that no merge is in progress
    ///   with ``LoreError/Code/internal``.
    public func abortMerge() async throws {
        _ = try await mergeOrRevert(
            merge: { try await perform(lore_branch_merge_abort_async, transform: { _ -> Never? in nil }) },
            revert: { try await perform(lore_revision_revert_abort_async, transform: { _ -> Never? in nil }) }
        )
    }

    /// Adds files to the merge in progress as merged changes.
    ///
    /// Use this method to stage a file again
    /// after you ``unstage(_:)`` a change that the merge made.
    /// A file whose conflict you hadn't resolved is in conflict again.
    ///
    /// Lore 0.12.0 supports this method only for a merge of a branch:
    /// for a revert or a cherry-pick,
    /// it throws ``LoreError/Code/internal``.
    ///
    /// - Parameter paths: The paths of the files, relative to the repository directory.
    /// - Throws: ``LoreError`` if the library can't stage the files.
    ///   Lore 0.12.0 reports that no merge is in progress
    ///   with ``LoreError/Code/internal``.
    public func stageMerged(_ paths: [String]) async throws {
        _ = try await perform(
            lore_file_stage_merge_async,
            configure: pathArguments(\lore_file_stage_merge_args_t.paths, paths),
            transform: { _ -> Never? in nil }
        )
    }

    /// Returns whether to call the revert functions of the library
    /// instead of its merge functions.
    ///
    /// The merge, revert, and cherry-pick functions of the library
    /// each act only on their own kind of operation.
    /// The status reports the merged revision of a merge in progress,
    /// including a merge that a sync stages,
    /// and no merged revision for a revert or a cherry-pick.
    /// The revert functions then fail for a cherry-pick
    /// or with no operation in progress,
    /// as the merge functions would.
    ///
    /// A merge whose conflicts are only in a linked repository
    /// leaves no merged revision in the status of this repository either,
    /// so ``mergeOrRevert(merge:revert:)`` calls the merge function
    /// when the revert function reports that the operation isn't a revert.
    private func isRevertInProgress() async throws -> Bool {
        let merged = try await perform(
            lore_repository_status_async,
            offline: true,
            configure: { (arguments: UnsafeMutablePointer<lore_repository_status_args_t>, _) in
                arguments.pointee.revision_only = 1
            },
            transform: { event -> Bool? in
                guard event.pointee.tag == LORE_EVENT_REPOSITORY_STATUS_REVISION.rawValue else {
                    return nil
                }
                return RevisionID(event.pointee.repository_status_revision.revision_merged) != nil
            }
        )
        return merged.last == false
    }

    /// Calls the revert function of the library for a revert in progress
    /// and its merge function otherwise.
    private func mergeOrRevert<Result>(
        merge: () async throws -> Result,
        revert: () async throws -> Result
    ) async throws -> Result {
        guard try await isRevertInProgress() else {
            return try await merge()
        }
        do {
            return try await revert()
        } catch let error as LoreError where error.code == .internal && error.message.contains("Invalid merge type") {
            return try await merge()
        }
    }

    /// Performs an operation that takes paths
    /// and returns the paths of the files it reports.
    private func conflictPaths<Arguments>(
        _ function: (
            UnsafePointer<lore_global_args_t>?,
            UnsafePointer<Arguments>?,
            lore_event_callback_config_t
        ) -> Void,
        _ keyPath: WritableKeyPath<Arguments, lore_string_array_t>,
        _ paths: [String]
    ) async throws -> [String] {
        let reported = try await perform(
            function,
            configure: pathArguments(keyPath, paths),
            transform: { event -> String? in
                switch event.pointee.tag {
                case LORE_EVENT_BRANCH_MERGE_RESOLVE_FILE.rawValue:
                    String(event.pointee.branch_merge_resolve_file.path)
                case LORE_EVENT_BRANCH_MERGE_UNRESOLVE_FILE.rawValue:
                    String(event.pointee.branch_merge_unresolve_file.path)
                case LORE_EVENT_REVERT_RESOLVE_FILE.rawValue:
                    String(event.pointee.revert_resolve_file.path)
                case LORE_EVENT_REVERT_UNRESOLVE_FILE.rawValue:
                    String(event.pointee.revert_unresolve_file.path)
                // Resolving with a side stages that version of each file.
                case LORE_EVENT_FILE_STAGE_FILE.rawValue:
                    String(event.pointee.file_stage_file.path)
                default:
                    nil
                }
            }
        )
        var seen: Set<String> = []
        return reported.filter { seen.insert($0).inserted }
    }

    /// Makes an argument configuration that sets the paths of an operation.
    private func pathArguments<Arguments>(
        _ keyPath: WritableKeyPath<Arguments, lore_string_array_t>,
        _ paths: [String]
    ) -> (UnsafeMutablePointer<Arguments>, Arena) -> Void {
        { arguments, arena in
            arguments.pointee[keyPath: keyPath] = arena.strings(paths)
        }
    }
}

/// An event of a branch diff.
private enum BranchDiffEvent: Sendable {
    case begin(source: RevisionID?, target: RevisionID?, base: RevisionID?)
    case change(BranchDiff.Change)
    case conflict(BranchDiff.Conflict)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_BRANCH_DIFF_BEGIN.rawValue:
            let data = event.pointee.branch_diff_begin
            self = .begin(
                source: RevisionID(data.source_revision),
                target: RevisionID(data.target_revision),
                base: RevisionID(data.base_revision)
            )
        case LORE_EVENT_BRANCH_DIFF_CHANGE.rawValue:
            self = .change(BranchDiff.Change(event.pointee.branch_diff_change.change))
        case LORE_EVENT_BRANCH_DIFF_CONFLICT.rawValue:
            let data = event.pointee.branch_diff_conflict
            self = .conflict(
                BranchDiff.Conflict(
                    source: BranchDiff.Change(data.source_change),
                    target: BranchDiff.Change(data.target_change)
                )
            )
        default:
            return nil
        }
    }
}

extension BranchDiff.Change {
    /// Copies the description of a changed node in a branch diff.
    fileprivate init(_ data: lore_branch_diff_node_data_t) {
        let previousPath = String(data.from_path)
        self.init(
            path: String(data.path),
            previousPath: previousPath.isEmpty ? nil : previousPath,
            action: FileAction(rawValue: data.action.rawValue),
            isAutomaticallyMerged: Bool(data.automerged)
        )
    }
}

/// An event of a merge, a revert, or a cherry-pick.
private enum MergeEvent: Sendable {
    case begin(RevisionID?)
    case conflict(String)
    case commit(CommitEvent)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_BRANCH_MERGE_START_BEGIN.rawValue:
            self = .begin(RevisionID(event.pointee.branch_merge_start_begin.revision))
        case LORE_EVENT_REVERT_START_BEGIN.rawValue:
            self = .begin(RevisionID(event.pointee.revert_start_begin.revision))
        case LORE_EVENT_CHERRY_PICK_START_BEGIN.rawValue:
            self = .begin(RevisionID(event.pointee.cherry_pick_start_begin.revision))
        case LORE_EVENT_BRANCH_MERGE_CONFLICT_FILE.rawValue:
            self = .conflict(String(event.pointee.branch_merge_conflict_file.path))
        case LORE_EVENT_REVERT_CONFLICT_FILE.rawValue:
            self = .conflict(String(event.pointee.revert_conflict_file.path))
        case LORE_EVENT_CHERRY_PICK_CONFLICT_FILE.rawValue:
            self = .conflict(String(event.pointee.cherry_pick_conflict_file.path))
        default:
            guard let commit = CommitEvent(event) else {
                return nil
            }
            self = .commit(commit)
        }
    }

    /// Folds the events of an operation into its result for this repository.
    ///
    /// A merge in a repository with links
    /// merges each linked repository first,
    /// and reports a begin event, conflicts, and a committed revision
    /// for each repository that it merges,
    /// without naming the repository except in the revision.
    /// A conflict in a linked repository stops the merge
    /// before it merges this repository,
    /// and the library reports the file twice:
    /// relative to the linked repository and relative to this one.
    ///
    /// - Parameters:
    ///   - events: The events of the operation.
    ///   - state: The state of this repository after the operation.
    ///   - isBranchMerge: Whether the operation merged a branch,
    ///     which leaves the merged revision in the state of this repository.
    static func result(_ events: [MergeEvent], in state: RepositoryState, isBranchMerge: Bool) throws -> MergeResult {
        var source: RevisionID?
        var conflicts: [String] = []
        var commits: [CommitEvent] = []
        for event in events {
            switch event {
            case .begin(let revision): source = revision
            case .conflict(let path): conflicts.append(path)
            case .commit(let event): commits.append(event)
            }
        }
        guard source != nil else {
            throw LoreError.missingEvent("the source revision")
        }
        // The begin event of this repository comes last,
        // but a merge that a linked repository's conflict stopped has none,
        // and the status can still report the incoming revision of an earlier merge.
        if isBranchMerge, source != state.mergedRevision {
            source = nil
        }
        var reported: Set<String> = []
        conflicts = conflicts.filter { state.unresolvedPaths.contains($0) && reported.insert($0).inserted }
        return MergeResult(
            sourceRevision: source,
            revision: CommitEvent.revision(of: state.repositoryID, in: commits),
            conflicts: conflicts
        )
    }
}

extension Repository {
    /// Folds the events of a merge, a revert, or a cherry-pick
    /// into its result for this repository.
    fileprivate func mergeResult(isBranchMerge: Bool, _ events: [MergeEvent]) async throws -> MergeResult {
        try MergeEvent.result(events, in: try await state(includingFiles: true), isBranchMerge: isBranchMerge)
    }
}
