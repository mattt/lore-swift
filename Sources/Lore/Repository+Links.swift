import CLore

/// A link from this repository to another repository.
///
/// A link mounts a directory of another repository at a path in this repository,
/// pinned to a revision of the other repository.
/// The revisions of this repository record the link,
/// so every clone of a revision has the linked files.
public struct Link: Sendable, Hashable {
    /// The path where the link is mounted, relative to the repository directory.
    public var path: String

    /// The identifier of the linked repository.
    public var repositoryID: RepositoryID

    /// The path of the mounted directory in the linked repository,
    /// or `/` for its root.
    public var sourcePath: String

    /// The revision of the linked repository that the link is pinned to.
    public var revision: RevisionID?

    /// The identifier of the branch of the linked repository that the link is on.
    ///
    /// Lore gives a branch that it creates in a linked repository
    /// the identifier of the matching branch in this repository.
    public var branchID: BranchID?

    /// A Boolean value that indicates whether the link follows
    /// the current branch of this repository
    /// instead of naming a branch of its own.
    ///
    /// When it does, ``branchID`` is the branch that the link resolved to.
    /// Updating the link names its branch.
    public var tracksCurrentBranch: Bool

    /// A Boolean value that indicates whether Lore creates
    /// a branch in the linked repository
    /// for each branch that you create in this repository.
    public var createsBranches: Bool
}

/// Information about a link and its staged changes.
public struct LinkInfo: Sendable, Hashable {
    /// A change to a link that is staged for the next commit.
    public enum StagedChange: UInt32, Sendable, Hashable {
        /// The link was added.
        case added = 1
        /// The link was removed.
        case removed = 2
        /// The link was pinned to another revision,
        /// or files in the linked repository were staged.
        case modified = 3
    }

    /// The link.
    ///
    /// Its ``Link/revision`` reflects the staged changes.
    public var link: Link

    /// The latest revision on the server
    /// of the branch that the link is on,
    /// or `nil` if the library didn't ask the server.
    public var remoteRevision: RevisionID?

    /// The staged change to the link,
    /// or `nil` if no change to the link is staged.
    public var stagedChange: StagedChange?

    /// The number of files in the linked repository
    /// that are staged for the next commit.
    public var stagedFileCount: Int
}

/// A link whose linked repository has files staged for the next commit.
public struct StagedLink: Sendable, Hashable {
    /// The path where the link is mounted, relative to the repository directory.
    public var path: String

    /// The identifier of the linked repository.
    public var repositoryID: RepositoryID

    /// The number of files in the linked repository
    /// that are staged for the next commit.
    public var stagedFileCount: Int
}

extension Repository {
    /// Links a directory of another repository into this repository.
    ///
    /// The link needs a server.
    /// Lore copies the linked files into the working directory at `path`
    /// and stages the link for the next commit.
    /// After you commit,
    /// staging and committing files under `path`
    /// commits them in the linked repository,
    /// and pushing pushes those revisions to the linked repository.
    ///
    /// - Parameters:
    ///   - repository: The URL of the repository to link,
    ///     or its name on the server of this repository.
    ///   - path: The path to mount the link at, relative to the repository directory.
    ///     The path must not exist or must be an empty directory.
    ///   - sourcePath: The path of a directory in the linked repository to mount,
    ///     or `nil` for its root.
    ///   - revision: The revision of the linked repository to pin the link to,
    ///     such as `main@2` or a revision ID,
    ///     or `nil` for the latest revision of the link's branch.
    ///   - creatingBranches: Whether the link follows the branches of this repository.
    ///     If `true`, the link is on the branch of the linked repository
    ///     that matches the current branch,
    ///     which Lore creates on the server if it doesn't exist,
    ///     and Lore creates a matching branch for each branch that you create.
    ///     If `false`, the link is on the default branch of the linked repository,
    ///     or on the branch of `revision`.
    /// - Returns: The revision of the linked repository that the link is pinned to.
    /// - Throws: ``LoreError`` if the library can't add the link,
    ///   such as ``LoreError/Code/noRemote`` in an offline repository,
    ///   ``LoreError/Code/notFound`` for a repository that doesn't exist,
    ///   or ``LoreError/Code/invalidArguments``
    ///   if the directory overlaps a directory of the same repository
    ///   that's already linked into this repository.
    @discardableResult
    public func addLink(
        to repository: String,
        at path: String,
        sourcePath: String? = nil,
        pinnedTo revision: RevisionSpecifier? = nil,
        creatingBranches: Bool = true
    ) async throws -> RevisionID {
        let changes = try await perform(
            lore_link_add_async,
            configure: { (arguments: UnsafeMutablePointer<lore_link_add_args_t>, arena) in
                arguments.pointee.link = arena.string(repository)
                arguments.pointee.link_path = arena.string(path)
                arguments.pointee.source_path = arena.string(sourcePath ?? "/")
                arguments.pointee.pin = arena.string(revision?.rawValue)
                arguments.pointee.disable_branching = UInt8(!creatingBranches)
            },
            transform: LinkChange.init
        )
        guard let revision = changes.last?.revision else {
            throw LoreError.missingEvent("the link")
        }
        return revision
    }

    /// Removes a link from this repository.
    ///
    /// Lore deletes the linked files from the working directory
    /// and stages the removal for the next commit.
    /// Removing a link that you added since the last commit
    /// unstages the link instead.
    ///
    /// - Parameter path: The path where the link is mounted,
    ///   relative to the repository directory.
    /// - Throws: ``LoreError`` if the library can't remove the link,
    ///   such as ``LoreError/Code/nodeNotFound`` if nothing exists at `path`,
    ///   or ``LoreError/Code/notALink`` if `path` isn't a link.
    public func removeLink(at path: String) async throws {
        _ = try await perform(
            lore_link_remove_async,
            configure: { (arguments: UnsafeMutablePointer<lore_link_remove_args_t>, arena) in
                arguments.pointee.link_path = arena.string(path)
            },
            transform: LinkChange.init
        )
    }

    /// Pins a link to another revision of the linked repository.
    ///
    /// The update needs a server.
    /// Lore updates the linked files in the working directory
    /// and stages the new pin for the next commit.
    ///
    /// - Parameters:
    ///   - path: The path where the link is mounted,
    ///     relative to the repository directory.
    ///   - revision: The revision of the linked repository to pin the link to,
    ///     such as `main@2` or a revision ID,
    ///     or `nil` for the latest revision on the server
    ///     of the branch that the link is on.
    /// - Returns: The revision that the link is pinned to,
    ///   or `nil` if the link was already pinned to it.
    /// - Throws: ``LoreError`` if the library can't update the link,
    ///   such as ``LoreError/Code/notALink`` if `path` isn't a link.
    ///   The library refuses to update a link whose addition, removal, or pin is staged,
    ///   or whose linked repository has staged files,
    ///   and reports that with ``LoreError/Code/internal``;
    ///   commit first.
    @discardableResult
    public func updateLink(at path: String, to revision: RevisionSpecifier? = nil) async throws -> RevisionID? {
        let changes = try await perform(
            lore_link_update_async,
            configure: { (arguments: UnsafeMutablePointer<lore_link_update_args_t>, arena) in
                arguments.pointee.link_path = arena.string(path)
                arguments.pointee.pin = arena.string(revision?.rawValue)
            },
            transform: LinkChange.init
        )
        guard let change = changes.last else {
            throw LoreError.missingEvent("the link")
        }
        // An unchanged link reports no revision.
        return change.revision
    }

    /// Lists the links of this repository,
    /// including links that are staged.
    ///
    /// - Returns: The links, in the order that the library reports them.
    /// - Throws: ``LoreError`` if the library can't list the links.
    public func links() async throws -> [Link] {
        try await perform(
            lore_link_list_async,
            configure: { (_: UnsafeMutablePointer<lore_link_list_args_t>, _) in },
            transform: { event -> Link? in
                guard event.pointee.tag == LORE_EVENT_LINK_ENTRY.rawValue else {
                    return nil
                }
                return Link(event.pointee.link_entry)
            }
        )
    }

    /// Returns information about a link and its staged changes.
    ///
    /// The information includes a link whose removal is staged.
    ///
    /// - Parameter path: The path where the link is mounted,
    ///   relative to the repository directory.
    /// - Returns: Information about the link.
    /// - Throws: ``LoreError`` if the library can't read the link,
    ///   such as ``LoreError/Code/nodeNotFound`` if nothing exists at `path`,
    ///   or ``LoreError/Code/notALink`` if `path` isn't a link.
    public func linkInfo(at path: String) async throws -> LinkInfo {
        let infos = try await perform(
            lore_link_info_async,
            configure: { (arguments: UnsafeMutablePointer<lore_link_info_args_t>, arena) in
                arguments.pointee.link_path = arena.string(path)
            },
            transform: { event -> LinkInfo? in
                guard event.pointee.tag == LORE_EVENT_LINK_INFO.rawValue else {
                    return nil
                }
                let data = event.pointee.link_info
                guard let link = Link(data.entry) else {
                    return nil
                }
                return LinkInfo(
                    link: link,
                    remoteRevision: RevisionID(data.remote_revision),
                    stagedChange: LinkInfo.StagedChange(rawValue: data.staged_state.rawValue),
                    stagedFileCount: Int(clamping: data.staged_file_count)
                )
            }
        )
        guard let info = infos.last else {
            throw LoreError.missingEvent("the link")
        }
        return info
    }

    /// Lists the links whose linked repositories have files
    /// staged for the next commit,
    /// including links inside linked repositories.
    ///
    /// - Returns: The links with staged files.
    /// - Throws: ``LoreError`` if the library can't list the links.
    public func stagedLinks() async throws -> [StagedLink] {
        try await perform(
            lore_link_list_staged_async,
            configure: { (_: UnsafeMutablePointer<lore_link_list_staged_args_t>, _) in },
            transform: { event -> StagedLink? in
                guard event.pointee.tag == LORE_EVENT_LINK_STAGED_ENTRY.rawValue else {
                    return nil
                }
                let data = event.pointee.link_staged_entry
                guard let repositoryID = RepositoryID(data.repository) else {
                    return nil
                }
                return StagedLink(
                    path: String(data.path),
                    repositoryID: repositoryID,
                    stagedFileCount: Int(clamping: data.staged_file_count)
                )
            }
        )
    }
}

extension Link {
    /// The flag of a link that doesn't create branches in the linked repository.
    private static let disableAutoFollow: UInt32 = 0b1

    /// Copies a link entry,
    /// returning `nil` if it names no repository.
    init?(_ data: lore_link_entry_event_data_t) {
        guard let repositoryID = RepositoryID(data.link) else {
            return nil
        }
        self.init(
            path: String(data.link_path),
            repositoryID: repositoryID,
            sourcePath: String(data.source_path),
            revision: RevisionID(data.revision),
            branchID: BranchID(data.branch),
            tracksCurrentBranch: Bool(data.tracking),
            createsBranches: data.flags & Self.disableAutoFollow == 0
        )
    }
}

/// A change to a link that an operation reports.
private struct LinkChange: Sendable {
    /// The revision that the link is pinned to,
    /// or `nil` for a removed link or an update that changed nothing.
    var revision: RevisionID?

    init?(_ event: UnsafePointer<lore_event_t>) {
        guard event.pointee.tag == LORE_EVENT_LINK_CHANGE.rawValue else {
            return nil
        }
        revision = RevisionID(event.pointee.link_change.revision)
    }
}
