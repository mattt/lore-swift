import CLore

/// A revision in the history of a file.
public struct FileRevision: Sendable, Hashable {
    /// The path of the file at the revision,
    /// relative to the repository directory.
    public var path: String

    /// The previous path of the file,
    /// if the revision moved it.
    public var previousPath: String?

    /// The change that the revision made to the file.
    public var action: FileAction

    /// The size of the file at the revision, in bytes.
    public var size: Int

    /// The revision, with its metadata.
    public var revision: Revision
}

/// Information about a file or directory in a repository.
public struct FileInfo: Sendable, Hashable {
    /// The path of the entry, relative to the repository directory.
    public var path: String

    /// The kind of entry.
    public var kind: NodeKind

    /// The size of the entry in the repository, in bytes.
    public var size: Int

    /// The size of the entry in the working directory, in bytes.
    public var localSize: Int

    /// A Boolean value that indicates whether the entry was added.
    public var isAdded: Bool

    /// A Boolean value that indicates whether the entry was modified.
    public var isModified: Bool

    /// A Boolean value that indicates whether the entry was deleted.
    public var isDeleted: Bool

    /// A Boolean value that indicates whether the library reports
    /// the entry as in conflict.
    ///
    /// Lore 0.11.0 reports `false` for the files of a merge in progress,
    /// including files whose conflicts aren't resolved;
    /// ``FileStatus/isConflicted`` reports those conflicts.
    public var isConflicted: Bool
}

/// The differences in the content of one file, as a unified diff.
public struct FileDiff: Sendable, Hashable {
    /// The path of the file, relative to the repository directory.
    public var path: String

    /// The change to the file.
    public var action: FileAction

    /// The differences in unified diff format.
    ///
    /// The `---` and `+++` header lines name each side of the comparison.
    /// A side where the file doesn't exist is `/dev/null`.
    /// The other sides are the path followed by `@` and the revision number,
    /// such as `a.txt@2`,
    /// except that the working directory and the target of an added file
    /// are the path alone.
    public var patch: String
}

/// A range of lines in a file and the revision that last changed them.
public struct LineAttribution: Sendable, Hashable {
    /// What a range of lines resolved to, or why it didn't resolve.
    ///
    /// Corresponds to `lore_file_audit_outcome_t`.
    public struct Outcome: RawRepresentable, Sendable, Hashable {
        /// The raw value of the outcome.
        public var rawValue: UInt32

        /// Creates an outcome from its raw value.
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// The lines resolved to the revision that last changed them.
        public static let attributed = Self(rawValue: LORE_FILE_AUDIT_OUTCOME_ATTRIBUTED.rawValue)
        /// The lines differ in the working directory from the revision that the audit read,
        /// so no revision has them.
        public static let uncommitted = Self(rawValue: LORE_FILE_AUDIT_OUTCOME_UNCOMMITTED.rawValue)
        /// The audit read as many revisions as its limit allows
        /// before the lines resolved.
        public static let revisionLimitReached = Self(rawValue: LORE_FILE_AUDIT_OUTCOME_BUDGET_EXHAUSTED.rawValue)
        /// A version of the file that the audit had to compare
        /// has no content, because it was obliterated.
        public static let obliterated = Self(rawValue: LORE_FILE_AUDIT_OUTCOME_OBLITERATED.rawValue)
        /// A version of the file that the audit had to compare
        /// has binary content, which can't be compared line by line.
        public static let binaryInHistory = Self(rawValue: LORE_FILE_AUDIT_OUTCOME_BINARY_IN_HISTORY.rawValue)
        /// The history continues in a linked repository
        /// that the audit can't reach or isn't authorized to read.
        public static let linkUnavailable = Self(rawValue: LORE_FILE_AUDIT_OUTCOME_LINK_UNAVAILABLE.rawValue)
        /// A version of the file that the audit had to compare
        /// isn't in the local store,
        /// and the audit reads only the local store.
        ///
        /// In Lore 0.11.0,
        /// after ``Repository/obliterate(contentAt:)`` removes an earlier version
        /// from the local store of an offline repository,
        /// an audit reports the lines whose attribution needs that version
        /// with this outcome,
        /// not with ``obliterated``.
        public static let contentUnavailable = Self(rawValue: LORE_FILE_AUDIT_OUTCOME_CONTENT_UNAVAILABLE.rawValue)
        /// An error ended the audit before it reached the lines.
        ///
        /// ``Repository/audit(_:revision:revisionLimit:ignoringTrailingWhitespace:ignoringWhitespaceChanges:)``
        /// throws the error instead of returning the ranges,
        /// so it never returns this outcome.
        public static let unresolved = Self(rawValue: LORE_FILE_AUDIT_OUTCOME_UNRESOLVED.rawValue)
    }

    /// The lines, numbered from 1.
    public var lines: ClosedRange<Int>

    /// The revision that last changed the lines,
    /// or `nil` unless ``outcome`` is ``Outcome/attributed``.
    public var revision: RevisionID?

    /// The repository of ``revision``:
    /// this repository,
    /// or a linked repository if the file's history continues in one.
    public var repositoryID: RepositoryID?

    /// What the lines resolved to, or why they didn't resolve.
    public var outcome: Outcome
}

extension Repository {
    /// Attributes each line of a file to the revision that last changed it.
    ///
    /// The result names each revision by its identifier;
    /// read the commit message and other metadata of a revision
    /// with ``revision(_:)``.
    ///
    /// - Parameters:
    ///   - path: The path of the file, relative to the repository directory.
    ///   - revision: The revision to read the file at,
    ///     or `nil` for the file in the working directory,
    ///     whose changed lines are ``LineAttribution/Outcome/uncommitted``.
    ///   - revisionLimit: The number of versions of the file to read,
    ///     or `nil` to read the whole history of the file.
    ///     Lines that the limit leaves unresolved are
    ///     ``LineAttribution/Outcome/revisionLimitReached``.
    ///   - ignoringTrailingWhitespace: Whether lines that differ only
    ///     in trailing whitespace are equal.
    ///   - ignoringWhitespaceChanges: Whether runs of whitespace within a line
    ///     compare equal to a single space,
    ///     so that a reindented line keeps the revision that wrote its text.
    /// - Returns: Ranges that together cover every line of the file,
    ///   in order of their lines.
    ///   An empty file has none.
    /// - Throws: ``LoreError`` if the library can't audit the file,
    ///   such as ``LoreError/Code/fileNotFound``
    ///   for a file that the revision doesn't have,
    ///   ``LoreError/Code/addressNotFound``
    ///   if ``obliterate(_:)`` removed the content of the file at `revision`,
    ///   or ``LoreError/Code/invalidArguments``
    ///   if `revisionLimit` is less than 1.
    ///   When an error ends the audit after it resolved some lines,
    ///   the method throws the error and discards those lines.
    public func audit(
        _ path: String,
        revision: RevisionSpecifier? = nil,
        revisionLimit: Int? = 100,
        ignoringTrailingWhitespace: Bool = true,
        ignoringWhitespaceChanges: Bool = false
    ) async throws -> [LineAttribution] {
        // The library reads a limit of 0 as its default of 100,
        // and `UInt32.max` as no limit.
        if let revisionLimit, revisionLimit < 1 {
            throw LoreError(
                code: .invalidArguments,
                message: "The revision limit must be at least 1, not \(revisionLimit)."
            )
        }
        let attributions = try await perform(
            lore_file_audit_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_audit_args_t>, arena) in
                arguments.pointee.path = arena.string(path)
                arguments.pointee.revision = arena.string(revision?.rawValue)
                arguments.pointee.max_revisions =
                    revisionLimit.map { UInt32(clamping: $0) } ?? UInt32.max
                arguments.pointee.no_ignore_space_at_eol = UInt8(!ignoringTrailingWhitespace)
                arguments.pointee.ignore_space_change = UInt8(ignoringWhitespaceChanges)
            },
            transform: { event -> LineAttribution? in
                guard event.pointee.tag == LORE_EVENT_FILE_AUDIT.rawValue else {
                    return nil
                }
                let data = event.pointee.file_audit
                let first = Int(data.line_first)
                return LineAttribution(
                    lines: first ... max(first, Int(data.line_last)),
                    revision: RevisionID(data.revision),
                    repositoryID: RepositoryID(data.repository),
                    outcome: LineAttribution.Outcome(rawValue: data.outcome.rawValue)
                )
            }
        )
        // The library reports the most recently changed lines first.
        return attributions.sorted { $0.lines.lowerBound < $1.lines.lowerBound }
    }

    /// Lists the revisions that changed a file, newest first.
    ///
    /// - Parameters:
    ///   - path: The path of the file, relative to the repository directory.
    ///   - revision: The revision to start from,
    ///     or `nil` for the current revision.
    ///   - branch: The name of the branch to search,
    ///     or `nil` for the current branch.
    ///   - limit: The maximum number of revisions to list,
    ///     or `nil` for no limit.
    /// - Returns: The revisions that changed the file.
    /// - Throws: ``LoreError`` if the library can't list the history,
    ///   such as ``LoreError/Code/fileNotFound``,
    ///   or with ``LoreError/Code/invalidArguments``
    ///   if `limit` is less than 1.
    public func history(
        of path: String,
        from revision: RevisionSpecifier? = nil,
        on branch: String? = nil,
        limit: Int? = nil
    ) async throws -> [FileRevision] {
        // The library reads a length of 0 as no limit.
        if let limit, limit < 1 {
            throw LoreError(code: .invalidArguments, message: "The limit must be at least 1, not \(limit).")
        }
        let events = try await perform(
            lore_file_history_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_history_args_t>, arena) in
                arguments.pointee.path = arena.string(path)
                arguments.pointee.revision = arena.string(revision?.rawValue)
                arguments.pointee.branch = arena.string(branch)
                arguments.pointee.length = UInt32(clamping: limit ?? 0)
            },
            transform: FileHistoryEvent.init
        )
        // The metadata entries of a revision follow its event.
        var history: [FileRevision] = []
        for event in events {
            switch event {
            case .revision(let revision):
                history.append(revision)
            case .metadata(let entry) where !history.isEmpty:
                history[history.count - 1].revision.add(entry)
            case .metadata:
                break
            }
        }
        // Lore 0.11.0 can list one revision more than the length it's given.
        if let limit {
            return Array(history.prefix(limit))
        }
        return history
    }

    /// Returns information about files and directories.
    ///
    /// - Parameters:
    ///   - paths: The paths of the entries, relative to the repository directory.
    ///   - revision: The revision to read,
    ///     or `nil` for the current revision.
    /// - Returns: Information about the entries that exist,
    ///   in the order that the library reports them.
    /// - Throws: ``LoreError`` if the library can't read the entries.
    public func fileInfo(
        of paths: [String],
        revision: RevisionSpecifier? = nil
    ) async throws -> [FileInfo] {
        try await perform(
            lore_file_info_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_info_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
                arguments.pointee.revision = arena.string(revision?.rawValue)
            },
            transform: { event -> FileInfo? in
                guard event.pointee.tag == LORE_EVENT_FILE_INFO.rawValue else {
                    return nil
                }
                let data = event.pointee.file_info
                return FileInfo(
                    path: String(data.path),
                    kind: Bool(data.is_dir) ? .directory : .file,
                    size: Int(clamping: data.size),
                    localSize: Int(clamping: data.local_size),
                    isAdded: Bool(data.flag_added),
                    isModified: Bool(data.flag_modified),
                    isDeleted: Bool(data.flag_deleted),
                    isConflicted: Bool(data.flag_conflict)
                )
            }
        )
    }

    /// Returns the differences in the content of files
    /// between a revision and another revision or the working directory.
    ///
    /// - Parameters:
    ///   - paths: The paths of the files, relative to the repository directory,
    ///     or an empty array for every file that differs.
    ///   - source: The revision to compare from.
    ///   - target: The revision to compare to,
    ///     or `nil` for the files in the working directory.
    ///   - contextLines: The number of unchanged lines to include around each change.
    ///   - ignoringTrailingWhitespace: Whether lines that differ only
    ///     in trailing whitespace are equal.
    ///   - ignoringWhitespaceChanges: Whether runs of whitespace within a line
    ///     compare equal to a single space.
    /// - Returns: The differences of each file that differs.
    /// - Throws: ``LoreError`` if the library can't compare the files.
    public func diff(
        of paths: [String] = [],
        from source: RevisionSpecifier,
        to target: RevisionSpecifier? = nil,
        contextLines: Int = 0,
        ignoringTrailingWhitespace: Bool = false,
        ignoringWhitespaceChanges: Bool = false
    ) async throws -> [FileDiff] {
        try await perform(
            lore_file_diff_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_diff_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
                arguments.pointee.source_revision = arena.string(source.rawValue)
                arguments.pointee.target_revision = arena.string(target?.rawValue)
                arguments.pointee.context_lines = UInt32(clamping: contextLines)
                arguments.pointee.ignore_whitespace_eol = UInt8(ignoringTrailingWhitespace)
                arguments.pointee.ignore_whitespace_inline = UInt8(ignoringWhitespaceChanges)
            },
            transform: { event -> FileDiff? in
                guard event.pointee.tag == LORE_EVENT_FILE_DIFF.rawValue else {
                    return nil
                }
                let data = event.pointee.file_diff
                return FileDiff(
                    path: String(data.path),
                    action: FileAction(rawValue: data.action.rawValue),
                    patch: String(data.patch)
                )
            }
        )
    }

    /// Removes files from the staged changes,
    /// keeping their content in the working directory.
    ///
    /// - Parameter paths: The paths to unstage, relative to the repository directory.
    /// - Returns: The changes that were unstaged.
    /// - Throws: ``LoreError`` if the library can't unstage the files.
    @discardableResult
    public func unstage(_ paths: [String]) async throws -> [FileChange] {
        try await perform(
            lore_file_unstage_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_unstage_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
            },
            transform: { event -> FileChange? in
                guard event.pointee.tag == LORE_EVENT_FILE_UNSTAGE_FILE.rawValue else {
                    return nil
                }
                let data = event.pointee.file_unstage_file
                return FileChange(path: String(data.path), action: FileAction(rawValue: data.action.rawValue))
            }
        )
    }

    /// Replaces files in the working directory with their content in a revision,
    /// discarding local changes.
    ///
    /// - Parameters:
    ///   - paths: The paths to reset, relative to the repository directory.
    ///     Pass `["."]` to reset every file.
    ///   - revision: The revision whose content to restore,
    ///     or `nil` for the current revision.
    ///   - deletingUntrackedFiles: Whether to delete the files under `paths`
    ///     that the repository doesn't track.
    /// - Returns: The files that were reset.
    /// - Throws: ``LoreError`` if the library can't reset the files.
    @discardableResult
    public func reset(
        _ paths: [String],
        to revision: RevisionSpecifier? = nil,
        deletingUntrackedFiles: Bool = false
    ) async throws -> [FileChange] {
        try await perform(
            lore_file_reset_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_reset_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
                arguments.pointee.revision = arena.string(revision?.rawValue)
                arguments.pointee.purge = UInt8(deletingUntrackedFiles)
            },
            transform: Self.resetChange
        )
    }

    /// Replaces files in the working directory with their content
    /// at the last merge from another branch into the current branch,
    /// discarding local changes.
    ///
    /// The other branch can be one that the current branch was created from,
    /// directly or through other branches.
    /// If the current branch has no merge from it,
    /// the files get their content at the revision of that branch
    /// that the current branch descends from.
    ///
    /// For a directory path, such as `"."`,
    /// Lore 0.11.0 resets the files under it to their content
    /// at that revision instead of the content of the merge.
    /// Pass the paths of files to restore the content of the merge.
    ///
    /// - Parameters:
    ///   - paths: The paths to reset, relative to the repository directory.
    ///   - branch: The name of the branch that the current branch merged from.
    ///   - side: The version of each file to restore:
    ///     the content that the merge committed,
    ///     or the version from either side of the merge.
    ///   - deletingUntrackedFiles: Whether to delete the files under `paths`
    ///     that the repository doesn't track.
    /// - Returns: The files that were reset.
    /// - Throws: ``LoreError`` if the library can't reset the files,
    ///   such as ``LoreError/Code/branchNotFound``
    ///   for a branch that doesn't exist or for the current branch.
    @discardableResult
    public func reset(
        _ paths: [String],
        toLastMergeFrom branch: String,
        keeping side: MergeSide = .merged,
        deletingUntrackedFiles: Bool = false
    ) async throws -> [FileChange] {
        try await perform(
            lore_file_reset_to_last_merged_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_reset_to_last_merged_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
                arguments.pointee.branch = arena.string(branch)
                arguments.pointee.purge = UInt8(deletingUntrackedFiles)
                arguments.pointee.merge_side =
                    switch side {
                    case .merged: 0
                    case .mine: 1
                    case .theirs: 2
                    }
            },
            transform: Self.resetChange
        )
    }

    /// Converts an event of a file reset.
    @Sendable private static func resetChange(_ event: UnsafePointer<lore_event_t>) -> FileChange? {
        guard event.pointee.tag == LORE_EVENT_FILE_RESET_FILE.rawValue else {
            return nil
        }
        let data = event.pointee.file_reset_file
        let previousPath = String(data.from_path)
        return FileChange(
            path: String(data.path),
            previousPath: previousPath.isEmpty ? nil : previousPath,
            action: FileAction(rawValue: data.action.rawValue)
        )
    }
}

/// An event of a file history.
private enum FileHistoryEvent: Sendable {
    case revision(FileRevision)
    case metadata(MetadataEntry)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_FILE_HISTORY.rawValue:
            let data = event.pointee.file_history
            guard let revision = Revision(data.revision, number: data.revision_number, parents: data.parent) else {
                return nil
            }
            let previousPath = String(data.from_path)
            self = .revision(
                FileRevision(
                    path: String(data.path),
                    previousPath: previousPath.isEmpty ? nil : previousPath,
                    action: FileAction(rawValue: data.action.rawValue),
                    size: Int(clamping: data.size),
                    revision: revision
                )
            )
        case LORE_EVENT_METADATA.rawValue:
            guard let entry = MetadataEntry(event) else {
                return nil
            }
            self = .metadata(entry)
        default:
            return nil
        }
    }
}
