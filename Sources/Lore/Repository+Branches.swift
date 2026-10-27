import CLore

/// A branch of a repository.
public struct Branch: Sendable, Hashable, Identifiable {
    /// Where a branch is held.
    public enum Location: UInt32, Sendable, Hashable {
        /// The branch is held locally.
        case local = 0
        /// The branch is held on the server.
        case remote = 1
    }

    /// The identifier of the branch.
    public var id: BranchID

    /// The name of the branch.
    public var name: String

    /// The category of the branch.
    public var category: String

    /// The latest revision of the branch,
    /// or `nil` if the branch has no revisions.
    public var latestRevision: RevisionID?

    /// Where the branch is held.
    public var location: Location

    /// The identifier of the user who created the branch.
    public var creator: String

    /// The creation time of the branch, as the library reports it.
    public var creationTimestamp: UInt64

    /// A Boolean value that indicates whether the branch
    /// is the current branch of the working directory.
    public var isCurrent: Bool

    /// A Boolean value that indicates whether the branch is archived.
    public var isArchived: Bool
}

extension Repository {
    /// Lists the branches of the repository.
    ///
    /// Unless the repository is offline,
    /// the list includes the branches on the server,
    /// so a branch can appear twice:
    /// once with each ``Branch/Location``.
    ///
    /// - Parameter includeArchived: Whether to include archived local branches.
    /// - Returns: The branches, in the order that the library reports them.
    /// - Throws: ``LoreError`` if the library can't list the branches.
    public func branches(includeArchived: Bool = false) async throws -> [Branch] {
        try await perform(
            lore_branch_list_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_list_args_t>, _) in
                arguments.pointee.archived = UInt8(includeArchived)
            },
            transform: { event -> Branch? in
                guard event.pointee.tag == LORE_EVENT_BRANCH_LIST_ENTRY.rawValue else {
                    return nil
                }
                let data = event.pointee.branch_list_entry
                guard let id = BranchID(data.id) else {
                    return nil
                }
                return Branch(
                    id: id,
                    name: String(data.name),
                    category: String(data.category),
                    latestRevision: RevisionID(data.latest),
                    location: Branch.Location(rawValue: data.location.rawValue) ?? .local,
                    creator: String(data.creator),
                    creationTimestamp: data.created,
                    isCurrent: Bool(data.is_current),
                    isArchived: Bool(data.archived)
                )
            }
        )
    }

    /// Creates a branch from the current revision.
    ///
    /// Creating a branch doesn't switch to it;
    /// call ``switchBranch(to:revision:discardingLocalChanges:)`` to do that.
    ///
    /// - Parameters:
    ///   - name: The name of the new branch.
    ///   - category: An optional category for the branch.
    /// - Returns: The latest revision of the new branch.
    /// - Throws: ``LoreError`` if the library can't create the branch,
    ///   such as ``LoreError/Code/branchAlreadyExists``.
    ///   Lore 0.11.0 refuses to create a branch in a repository without revisions
    ///   and reports that with ``LoreError/Code/internal``.
    @discardableResult
    public func createBranch(named name: String, category: String? = nil) async throws -> RevisionID? {
        let revisions = try await perform(
            lore_branch_create_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_create_args_t>, arena) in
                arguments.pointee.branch = arena.string(name)
                arguments.pointee.category = arena.string(category)
            },
            transform: { event -> RevisionID?? in
                guard event.pointee.tag == LORE_EVENT_BRANCH_CREATE.rawValue else {
                    return nil
                }
                return .some(RevisionID(event.pointee.branch_create.latest))
            }
        )
        return revisions.last ?? nil
    }

    /// Switches the working directory to a branch.
    ///
    /// - Parameters:
    ///   - name: The name of the branch.
    ///   - revision: A revision on the branch to switch to,
    ///     or `nil` for its latest revision.
    ///   - discardingLocalChanges: Whether to replace local changes
    ///     with the content of the revision.
    /// - Returns: The revision that the working directory holds after the switch.
    /// - Throws: ``LoreError`` if the library can't switch,
    ///   such as ``LoreError/Code/branchNotFound``.
    @discardableResult
    public func switchBranch(
        to name: String,
        revision: String? = nil,
        discardingLocalChanges: Bool = false
    ) async throws -> RevisionID? {
        let revisions = try await perform(
            lore_branch_switch_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_switch_args_t>, arena) in
                arguments.pointee.branch = arena.string(name)
                arguments.pointee.revision = arena.string(revision)
                arguments.pointee.reset = UInt8(discardingLocalChanges)
            },
            transform: { event -> RevisionID?? in
                guard event.pointee.tag == LORE_EVENT_BRANCH_SWITCH_END.rawValue else {
                    return nil
                }
                return .some(RevisionID(event.pointee.branch_switch_end.branch.revision))
            }
        )
        return revisions.last ?? nil
    }
}
