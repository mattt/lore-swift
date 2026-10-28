import CLore
import Foundation

/// A change that an operation applied to a file.
public struct FileChange: Sendable, Hashable {
    /// The path of the file, relative to the repository directory.
    public var path: String

    /// The previous path of a moved file.
    public var previousPath: String?

    /// The change to the file.
    public var action: FileAction

    /// The kind of node,
    /// or `nil` if the operation doesn't report it.
    public var kind: NodeKind?
}

/// A revision on a branch.
public struct Revision: Sendable, Hashable, Identifiable {
    /// The hash signature of the revision.
    public var id: RevisionID

    /// The number of the revision on its branch.
    public var number: Int

    /// The parents of the revision:
    /// none for the first revision,
    /// two for a merge.
    public var parents: [RevisionID]

    /// The identifier of the branch of the revision.
    public var branchID: BranchID?

    /// The metadata of the revision, by key.
    ///
    /// Lore records the commit message, the commit time, the branch,
    /// and the identities of the creator and the committer
    /// as metadata of each revision,
    /// along with the values that you set
    /// with ``Repository/setRevisionMetadata(_:)``.
    public var metadata: [String: MetadataValue] = [:]
}

extension Revision {
    /// The commit message,
    /// from the `message` metadata value.
    public var message: String? {
        if case .string(let message) = metadata["message"] { message } else { nil }
    }

    /// The time of the commit,
    /// from the `timestamp` metadata value.
    public var date: Date? {
        if case .number(let milliseconds) = metadata["timestamp"] {
            Date(millisecondsSince1970: milliseconds)
        } else {
            nil
        }
    }

    /// The identity of the user who created the revision,
    /// from the `created-by` metadata value.
    public var creator: String? {
        if case .string(let creator) = metadata["created-by"] { creator } else { nil }
    }

    /// Creates a revision without metadata
    /// from a hash, a number, and a pair of parent hashes.
    ///
    /// Returns `nil` for the all-zero hash.
    init?(_ revision: lore_hash_t, number: UInt64, parents: (lore_hash_t, lore_hash_t)) {
        guard let id = RevisionID(revision) else {
            return nil
        }
        self.id = id
        self.number = Int(clamping: number)
        self.parents = [RevisionID(parents.0), RevisionID(parents.1)].compactMap { $0 }
    }

    /// Adds a metadata entry,
    /// taking the branch from the `branch` value.
    mutating func add(_ entry: MetadataEntry) {
        metadata[entry.key] = entry.value
        if entry.key == "branch", case .context(let bytes) = entry.value {
            branchID = BranchID(bytes: bytes)
        }
    }
}

extension Repository {
    /// Stages files for the next commit.
    ///
    /// Staging a file records its current content, addition, or deletion.
    /// Staging a directory stages the changed files under it.
    ///
    /// - Parameters:
    ///   - paths: The paths to stage, relative to the repository directory.
    ///     Pass `["."]` to stage every change.
    ///   - scanning: Whether to scan the directories in `paths` for changes
    ///     that the repository hasn't recorded yet.
    /// - Returns: The changes that were staged.
    /// - Throws: ``LoreError`` if the library can't stage the files.
    @discardableResult
    public func stage(_ paths: [String], scanning: Bool = true) async throws -> [FileChange] {
        try await perform(
            lore_file_stage_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_stage_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
                arguments.pointee.scan = UInt8(scanning)
            },
            transform: { event in
                guard event.pointee.tag == LORE_EVENT_FILE_STAGE_FILE.rawValue else {
                    return nil
                }
                let data = event.pointee.file_stage_file
                let previousPath = String(data.from_path)
                return FileChange(
                    path: String(data.path),
                    previousPath: previousPath.isEmpty ? nil : previousPath,
                    action: FileAction(rawValue: data.action.rawValue)
                )
            }
        )
    }

    /// Commits the staged changes as a new revision on the current branch.
    ///
    /// The new revision is local
    /// until you ``push(branch:allowingFastForward:)`` it.
    ///
    /// - Parameter message: The commit message.
    /// - Returns: The new revision, with its metadata.
    /// - Throws: ``LoreError`` if the library can't commit,
    ///   such as ``LoreError/Code/nothingStaged``,
    ///   ``LoreError/Code/missingIdentity``,
    ///   or ``LoreError/Code/conflict``
    ///   when a file of a merge has a conflict that isn't resolved.
    @discardableResult
    public func commit(message: String) async throws -> Revision {
        let events = try await perform(
            lore_revision_commit_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_commit_args_t>, arena) in
                arguments.pointee.message = arena.string(message)
            },
            transform: CommitEvent.init
        )
        return try CommitEvent.revision(events)
    }

    /// Replaces the commit message of the current revision.
    ///
    /// Amending makes a new revision with the same number, parents,
    /// changes, and other metadata,
    /// and makes it the current revision and the latest revision of the branch.
    /// The changes that you've staged aren't part of it.
    ///
    /// In Lore 0.11.0,
    /// committing changes that you staged before an amend
    /// fails with ``LoreError/Code/internal``;
    /// ``unstage(_:)`` and ``stage(_:scanning:)`` them again first.
    ///
    /// - Parameter message: The new commit message.
    /// - Returns: The amended revision, with its metadata.
    /// - Throws: ``LoreError`` if the library can't amend the revision.
    @discardableResult
    public func amend(message: String) async throws -> Revision {
        let events = try await perform(
            lore_revision_amend_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_amend_args_t>, arena) in
                arguments.pointee.message = arena.string(message)
            },
            transform: CommitEvent.init
        )
        return try CommitEvent.revision(events)
    }
}

/// An event of a commit.
enum CommitEvent: Sendable {
    case revision(Revision)
    case metadata(MetadataEntry)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_REVISION_COMMIT_REVISION.rawValue:
            let data = event.pointee.revision_commit_revision
            guard
                var revision = Revision(
                    data.revision,
                    number: data.revision_number,
                    parents: (data.parent, data.parent_other)
                )
            else {
                return nil
            }
            revision.branchID = BranchID(data.branch)
            self = .revision(revision)
        case LORE_EVENT_METADATA.rawValue:
            guard let entry = MetadataEntry(event) else {
                return nil
            }
            self = .metadata(entry)
        default:
            return nil
        }
    }

    /// Returns the committed revision with the metadata that the commit reports.
    static func revision(_ events: [CommitEvent]) throws -> Revision {
        var revisions: [Revision] = []
        var metadata: [MetadataEntry] = []
        for event in events {
            switch event {
            case .revision(let revision): revisions.append(revision)
            case .metadata(let entry): metadata.append(entry)
            }
        }
        guard var revision = revisions.last else {
            throw LoreError.missingEvent("a revision")
        }
        revision.metadata = Dictionary(metadata)
        return revision
    }
}
