import CLore
import Foundation

extension Repository {
    /// Lists the revisions of a branch, newest first.
    ///
    /// The history follows the first parent of each revision,
    /// so the history of a branch continues
    /// into the history of the branch it was created from.
    ///
    /// - Parameters:
    ///   - revision: The revision to start from,
    ///     or `nil` for the current revision.
    ///   - branch: The name of the branch to list,
    ///     or `nil` for the current branch.
    ///   - date: The earliest commit time to include,
    ///     or `nil` for no limit.
    ///   - limit: The maximum number of revisions to list,
    ///     or `nil` for no limit.
    ///   - stoppingAtBranchPoint: Whether to end the history
    ///     at the first revision from another branch,
    ///     such as the revision that the branch was created from.
    /// - Returns: The revisions, with their metadata.
    /// - Throws: ``LoreError`` if the library can't list the history,
    ///   or with ``LoreError/Code/invalidArguments``
    ///   if `limit` is less than 1
    ///   or `date` isn't finite or is too late for a library timestamp.
    public func history(
        from revision: RevisionSpecifier? = nil,
        on branch: String? = nil,
        since date: Date? = nil,
        limit: Int? = nil,
        stoppingAtBranchPoint: Bool = false
    ) async throws -> [Revision] {
        // The library reads a length of 0 as no limit.
        if let limit, limit < 1 {
            throw LoreError(code: .invalidArguments, message: "The limit must be at least 1, not \(limit).")
        }
        // The library reads a date of 0 as no limit,
        // which includes every revision, as a date before 1970 does.
        var timestamp: UInt64 = 0
        if let date {
            guard let milliseconds = UInt64(timestampAtOrAfter: date) else {
                throw LoreError(
                    code: .invalidArguments,
                    message: "The date can't be expressed as a library timestamp: \(date.timeIntervalSince1970)."
                )
            }
            timestamp = milliseconds
        }
        let events = try await perform(
            lore_revision_history_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_history_args_t>, arena) in
                arguments.pointee.revision = arena.string(revision?.rawValue)
                arguments.pointee.branch = arena.string(branch)
                arguments.pointee.date = timestamp
                arguments.pointee.length = UInt32(clamping: limit ?? 0)
                arguments.pointee.only_branch = UInt8(stoppingAtBranchPoint)
            },
            transform: RevisionEvent.init
        )
        return RevisionEvent.revisions(events)
    }

    /// Returns a revision with its metadata.
    ///
    /// - Parameter revision: The revision, or `nil` for the current revision.
    /// - Returns: The revision.
    /// - Throws: ``LoreError`` if the library can't read the revision,
    ///   such as ``LoreError/Code/revisionNotFound``.
    public func revision(_ revision: RevisionSpecifier? = nil) async throws -> Revision {
        let events = try await perform(
            lore_revision_info_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_info_args_t>, arena) in
                arguments.pointee.revision = arena.string(revision?.rawValue)
            },
            transform: RevisionEvent.init
        )
        guard let revision = RevisionEvent.revisions(events).last else {
            throw LoreError.missingEvent("a revision")
        }
        return revision
    }

    /// Lists the changes that a revision made to its first parent.
    ///
    /// The changes include the directories that the revision added or deleted.
    ///
    /// - Parameter revision: The revision, or `nil` for the current revision.
    /// - Returns: The changes.
    /// - Throws: ``LoreError`` if the library can't read the revision,
    ///   such as ``LoreError/Code/revisionNotFound``.
    public func changes(in revision: RevisionSpecifier? = nil) async throws -> [FileChange] {
        let events = try await perform(
            lore_revision_info_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_info_args_t>, arena) in
                arguments.pointee.revision = arena.string(revision?.rawValue)
                arguments.pointee.delta = 1
            },
            transform: RevisionEvent.init
        )
        return events.compactMap { event in
            if case .change(let change) = event { change } else { nil }
        }
    }

    /// Lists the files that differ between two revisions.
    ///
    /// The changes include the directories that differ.
    ///
    /// - Parameters:
    ///   - source: The revision to compare from.
    ///   - target: The revision to compare to,
    ///     or `nil` for the current revision.
    ///   - paths: The paths to compare, relative to the repository directory,
    ///     or an empty array for every path.
    /// - Returns: The changes that turn `source` into `target`.
    /// - Throws: ``LoreError`` if the library can't compare the revisions,
    ///   such as ``LoreError/Code/revisionNotFound``.
    public func changes(
        from source: RevisionSpecifier,
        to target: RevisionSpecifier? = nil,
        paths: [String] = []
    ) async throws -> [FileChange] {
        try await perform(
            lore_revision_diff_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_diff_args_t>, arena) in
                arguments.pointee.revision_source = arena.string(source.rawValue)
                arguments.pointee.revision_target = arena.string(target?.rawValue)
                arguments.pointee.paths = arena.strings(paths)
            },
            transform: { event -> FileChange? in
                guard event.pointee.tag == LORE_EVENT_REVISION_DIFF_FILE.rawValue else {
                    return nil
                }
                let data = event.pointee.revision_diff_file
                let previousPath = String(data.from_path)
                return FileChange(
                    path: String(data.path),
                    previousPath: previousPath.isEmpty ? nil : previousPath,
                    action: FileAction(rawValue: data.action.rawValue),
                    kind: Bool(data.old_is_file) || Bool(data.new_is_file) ? .file : .directory
                )
            }
        )
    }

    /// Commits the content of the revision that the working directory holds
    /// as a new revision on top of the latest revision of the current branch.
    ///
    /// Sync to an earlier revision with ``sync(to:discardingLocalChanges:)``,
    /// then call this method to make its content the latest.
    /// Restoring needs a server:
    /// the new revision is on the server when the method returns.
    /// Its `restored-from` metadata value is the hash of the restored revision.
    ///
    /// - Parameter message: The commit message for the new revision.
    /// - Returns: The new revision, with its metadata.
    /// - Throws: ``LoreError`` if the library can't restore the revision.
    ///   Lore 0.12.0 reports an offline repository
    ///   with ``LoreError/Code/internal``.
    @discardableResult
    public func restore(message: String) async throws -> Revision {
        let revisions = try await perform(
            lore_revision_restore_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_restore_args_t>, arena) in
                arguments.pointee.message = arena.string(message)
            },
            transform: { event -> RevisionID? in
                guard event.pointee.tag == LORE_EVENT_REVISION_RESTORE_REVISION.rawValue else {
                    return nil
                }
                return RevisionID(event.pointee.revision_restore_revision.revision)
            }
        )
        guard let id = revisions.last else {
            throw LoreError.missingEvent("a revision")
        }
        // The restore reports the new revision's hash and number,
        // but not its parents or metadata.
        return try await revision(.id(id))
    }
}

// MARK: - Finding revisions

extension Repository {
    /// Returns the newest revision of the current branch
    /// with a metadata value for a key.
    ///
    /// The search starts at the latest revision of the current branch,
    /// on the server unless the repository is offline,
    /// and follows the first parent of each revision,
    /// so it continues into the history of the branch
    /// that the current branch was created from.
    ///
    /// Lore reads the stored bytes of each value as text,
    /// so `value` matches ``MetadataValue/string(_:)`` values,
    /// such as the `message` that Lore records for every revision.
    /// Without a `value`,
    /// a revision matches if the bytes of its value for the key are valid UTF-8,
    /// which every string value is,
    /// and a value of another type can be.
    ///
    /// - Parameters:
    ///   - key: The metadata key.
    ///   - value: The text to match,
    ///     or `nil` to match any value for the key that reads as text.
    /// - Returns: The revision, with its metadata,
    ///   or `nil` if no revision matches.
    /// - Throws: ``LoreError`` if the library can't search,
    ///   or ``LoreError/Code/invalidArguments`` for an empty key.
    public func findRevision(withMetadataKey key: String, value: String? = nil) async throws -> Revision? {
        guard !key.isEmpty else {
            throw LoreError(code: .invalidArguments, message: "The metadata key is empty.")
        }
        return try await findRevision { arguments, arena in
            arguments.pointee.key = arena.string(key)
            arguments.pointee.value = arena.string(value)
        }
    }

    /// Returns the revision with a number
    /// in the history of the current branch.
    ///
    /// The search starts at the latest revision of the current branch,
    /// on the server unless the repository is offline,
    /// and follows the first parent of each revision,
    /// so it continues into the history of the branch
    /// that the current branch was created from,
    /// where ``RevisionSpecifier/number(_:on:)`` names only
    /// the revisions of one branch.
    ///
    /// - Parameter number: The number of the revision.
    /// - Returns: The revision, with its metadata,
    ///   or `nil` if the history has no revision with the number.
    /// - Throws: ``LoreError`` if the library can't search,
    ///   or ``LoreError/Code/invalidArguments``
    ///   if `number` is less than 1.
    public func findRevision(numbered number: Int) async throws -> Revision? {
        // The library reads a number of 0 as no search.
        guard number >= 1 else {
            throw LoreError(code: .invalidArguments, message: "The revision number must be at least 1, not \(number).")
        }
        return try await findRevision { arguments, _ in
            arguments.pointee.number = UInt64(number)
        }
    }

    private func findRevision(
        configure: (UnsafeMutablePointer<lore_revision_find_args_t>, Arena) -> Void
    ) async throws -> Revision? {
        let found: [RevisionID?]
        do {
            found = try await perform(
                lore_revision_find_async,
                configure: configure,
                transform: { event -> RevisionID?? in
                    guard event.pointee.tag == LORE_EVENT_REVISION_FIND.rawValue else {
                        return nil
                    }
                    return .some(RevisionID(event.pointee.revision_find.signature))
                }
            )
        } catch let error as LoreError where error.code == .internal && error.message == "no revision found" {
            // Lore 0.12.0 reports a search without a match as an internal error.
            return nil
        }
        guard let id = found.last else {
            throw LoreError.missingEvent("a revision")
        }
        guard let id else {
            return nil
        }
        return try await revision(.id(id))
    }
}

// MARK: - Bisecting

/// One step of a search for the revision that introduced a change.
public struct BisectStep: Sendable, Hashable {
    /// The revision halfway between the start and the end of the range,
    /// which the working directory now holds.
    ///
    /// When the search ``isFinished``, it's the end of the range:
    /// the first revision with the change.
    public var revision: Revision

    /// The number of the revision at the start of the range.
    public var startNumber: Int

    /// The number of the revision at the end of the range.
    public var endNumber: Int

    /// A Boolean value that indicates whether the end of the range
    /// is the child of its start,
    /// so the end is the first revision with the change.
    public var isFinished: Bool
}

extension Repository {
    /// Takes one step of a search for the revision that introduced a change,
    /// syncing the working directory to the revision halfway between two revisions.
    ///
    /// The search follows the first parent of each revision
    /// from `end` back to `start`.
    /// Test the working directory after each step,
    /// then take the next step with the half of the range that has the change,
    /// until the step ``BisectStep/isFinished``:
    ///
    /// ```swift
    /// var start: RevisionSpecifier = "main@1"
    /// var end: RevisionSpecifier = .latest()
    /// while true {
    ///     let step = try await repository.bisect(between: start, and: end)
    ///     if step.isFinished {
    ///         print("Introduced by revision", step.revision.number)
    ///         break
    ///     }
    ///     if try hasChange() {
    ///         end = .id(step.revision.id)
    ///     } else {
    ///         start = .id(step.revision.id)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - start: A revision without the change.
    ///   - end: A later revision with the change,
    ///     whose first-parent history includes `start`.
    /// - Returns: The step, with the revision that the working directory holds.
    /// - Throws: ``LoreError`` if the library can't take the step,
    ///   such as ``LoreError/Code/revisionNotFound``
    ///   or ``LoreError/Code/localModifications``.
    ///   Lore 0.12.0 reports a `start` that isn't in the history of `end`,
    ///   including the same revision,
    ///   with ``LoreError/Code/internal``.
    public func bisect(between start: RevisionSpecifier, and end: RevisionSpecifier) async throws -> BisectStep {
        let steps = try await perform(
            lore_revision_bisect_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_bisect_args_t>, arena) in
                arguments.pointee.start = arena.string(start.rawValue)
                arguments.pointee.end = arena.string(end.rawValue)
            },
            transform: { event -> (start: Int, end: Int, isFinished: Bool)? in
                guard event.pointee.tag == LORE_EVENT_REVISION_BISECT.rawValue else {
                    return nil
                }
                let data = event.pointee.revision_bisect
                return (
                    Int(clamping: data.start_revision_number),
                    Int(clamping: data.end_revision_number),
                    Bool(data.done)
                )
            }
        )
        guard let step = steps.last else {
            throw LoreError.missingEvent("a bisect step")
        }
        // The bisect syncs this repository and any links,
        // whose sync events don't all say which repository they describe,
        // so the binding reads the revision that the working directory holds.
        return BisectStep(
            revision: try await revision(),
            startNumber: step.start,
            endNumber: step.end,
            isFinished: step.isFinished
        )
    }
}

// MARK: - Revision metadata

extension Repository {
    /// Returns the metadata value of a revision for a key.
    ///
    /// - Parameters:
    ///   - key: The metadata key.
    ///   - revision: The revision to read,
    ///     or `nil` for the metadata of the next commit
    ///     once you set or clear any,
    ///     and the metadata of the current revision before that.
    /// - Returns: The value, or `nil` if the revision has no value for the key.
    /// - Throws: ``LoreError`` if the library can't read the metadata.
    public func revisionMetadata(
        forKey key: String,
        of revision: RevisionSpecifier? = nil
    ) async throws -> MetadataValue? {
        try await metadataEntries(
            lore_revision_metadata_get_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_metadata_get_args_t>, arena) in
                arguments.pointee.key = arena.string(key)
                arguments.pointee.revision = arena.string(revision?.rawValue)
            }
        )[key]
    }

    /// Returns the metadata of a revision.
    ///
    /// - Parameter revision: The revision to read,
    ///   or `nil` for the metadata of the next commit
    ///   once you set or clear any,
    ///   and the metadata of the current revision before that.
    /// - Returns: The metadata values, by key.
    /// - Throws: ``LoreError`` if the library can't read the metadata.
    public func revisionMetadata(of revision: RevisionSpecifier? = nil) async throws -> [String: MetadataValue] {
        try await metadataEntries(
            lore_revision_metadata_list_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_metadata_list_args_t>, arena) in
                arguments.pointee.revision = arena.string(revision?.rawValue)
            }
        )
    }

    /// Sets metadata values for the next commit.
    ///
    /// The next ``commit(message:linkMessages:)`` records the values
    /// along with the metadata that Lore records for every revision.
    /// A commit still needs staged changes.
    ///
    /// - Parameter values: The values to set, by key.
    /// - Throws: ``LoreError`` if the library can't set the metadata,
    ///   or with ``LoreError/Code/notSupported``
    ///   for a ``MetadataValue/binary(_:)``
    ///   or ``MetadataValue/address(hash:context:)`` value,
    ///   which the binding can't set.
    public func setRevisionMetadata(_ values: [String: MetadataValue]) async throws {
        let metadata = try EncodedMetadata(values)
        _ = try await perform(
            lore_revision_metadata_set_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_metadata_set_args_t>, arena) in
                arguments.pointee.keys = arena.strings(metadata.keys)
                arguments.pointee.values = arena.strings(metadata.texts)
                arguments.pointee.formats = metadata.formats(in: arena)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Removes the metadata values that you set for the next commit.
    ///
    /// - Throws: ``LoreError`` if the library can't clear the metadata.
    public func clearRevisionMetadata() async throws {
        _ = try await perform(
            lore_revision_metadata_clear_async,
            transform: { _ -> Never? in nil }
        )
    }
}

/// An event that describes a revision.
///
/// The metadata entries of a revision follow its event.
private enum RevisionEvent: Sendable {
    case revision(Revision)
    case metadata(MetadataEntry)
    case change(FileChange)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_REVISION_HISTORY_ENTRY.rawValue:
            let data = event.pointee.revision_history_entry
            guard let revision = Revision(data.revision, number: data.revision_number, parents: data.parent) else {
                return nil
            }
            self = .revision(revision)
        case LORE_EVENT_REVISION_INFO.rawValue:
            let data = event.pointee.revision_info
            guard let revision = Revision(data.revision, number: data.revision_number, parents: data.parent) else {
                return nil
            }
            self = .revision(revision)
        case LORE_EVENT_REVISION_INFO_DELTA.rawValue:
            let data = event.pointee.revision_info_delta
            let previousPath = String(data.from_path)
            self = .change(
                FileChange(
                    path: String(data.path),
                    previousPath: previousPath.isEmpty ? nil : previousPath,
                    action: FileAction(rawValue: data.action.rawValue),
                    kind: Bool(data.flag_file) ? .file : .directory
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

    /// Collects the revisions and the metadata that follows each one.
    static func revisions(_ events: [RevisionEvent]) -> [Revision] {
        var revisions: [Revision] = []
        for event in events {
            switch event {
            case .revision(let revision):
                revisions.append(revision)
            case .metadata(let entry) where !revisions.isEmpty:
                revisions[revisions.count - 1].add(entry)
            case .metadata, .change:
                break
            }
        }
        return revisions
    }
}
