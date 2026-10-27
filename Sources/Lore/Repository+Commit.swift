import CLore

/// A change that an operation applied to a file.
public struct FileChange: Sendable, Hashable {
    /// The path of the file, relative to the repository directory.
    public var path: String

    /// The previous path of a moved file.
    public var previousPath: String?

    /// The change to the file.
    public var action: FileAction
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
    /// - Returns: The new revision.
    /// - Throws: ``LoreError`` if the library can't commit,
    ///   such as ``LoreError/Code/nothingStaged``
    ///   or ``LoreError/Code/missingIdentity``.
    @discardableResult
    public func commit(message: String) async throws -> Revision {
        let revisions = try await perform(
            lore_revision_commit_async,
            configure: { (arguments: UnsafeMutablePointer<lore_revision_commit_args_t>, arena) in
                arguments.pointee.message = arena.string(message)
            },
            transform: { event -> Revision? in
                guard event.pointee.tag == LORE_EVENT_REVISION_COMMIT_REVISION.rawValue else {
                    return nil
                }
                let data = event.pointee.revision_commit_revision
                guard let id = RevisionID(data.revision) else {
                    return nil
                }
                return Revision(
                    id: id,
                    number: Int(clamping: data.revision_number),
                    parents: [RevisionID(data.parent), RevisionID(data.parent_other)]
                        .compactMap { $0 },
                    branchID: BranchID(data.branch)
                )
            }
        )
        guard let revision = revisions.last else {
            throw LoreError.missingEvent("a revision")
        }
        return revision
    }
}
