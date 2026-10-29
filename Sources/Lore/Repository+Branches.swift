import CLore
import Foundation

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

    /// The time the branch was created.
    public var creationDate: Date

    /// A Boolean value that indicates whether the branch
    /// is the current branch of the working directory.
    public var isCurrent: Bool

    /// A Boolean value that indicates whether the branch is archived.
    public var isArchived: Bool
}

/// Information about a branch and where it was created from.
public struct BranchInfo: Sendable, Hashable, Identifiable {
    /// The identifier of the branch.
    public var id: BranchID

    /// The name of the branch.
    public var name: String

    /// The category of the branch.
    public var category: String

    /// The latest revision of the branch in the repository,
    /// or `nil` if the branch has no revisions.
    public var latestRevision: RevisionID?

    /// The latest revision of the branch on the server,
    /// or `nil` if it's unknown.
    public var remoteLatestRevision: RevisionID?

    /// The identifier of the branch that the branch was created from,
    /// or `nil` for a branch that wasn't created from another branch.
    public var parentID: BranchID?

    /// The revision that the branch was created from,
    /// or `nil` for a branch that wasn't created from another branch.
    public var branchPoint: RevisionID?

    /// The identifier of the user who created the branch.
    public var creator: String

    /// The time the branch was created.
    public var creationDate: Date

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
    /// - Parameter includingArchived: Whether to include archived local branches.
    /// - Returns: The branches, in the order that the library reports them.
    /// - Throws: ``LoreError`` if the library can't list the branches.
    public func branches(includingArchived: Bool = false) async throws -> [Branch] {
        try await perform(
            lore_branch_list_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_list_args_t>, _) in
                arguments.pointee.archived = UInt8(includingArchived)
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
                    creationDate: Date(millisecondsSince1970: data.created),
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
    ///   Lore 0.12.0 refuses to create a branch in a repository without revisions
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
        revision: RevisionSpecifier? = nil,
        discardingLocalChanges: Bool = false
    ) async throws -> RevisionID? {
        let revisions = try await perform(
            lore_branch_switch_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_switch_args_t>, arena) in
                arguments.pointee.branch = arena.string(name)
                arguments.pointee.revision = arena.string(revision?.rawValue)
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

    /// Returns information about a branch.
    ///
    /// - Parameters:
    ///   - name: The name of the branch,
    ///     or `nil` for the current branch.
    ///   - link: The path where a link is mounted,
    ///     to read the branch of the linked repository,
    ///     or `nil` to read the branch of this repository.
    /// - Returns: Information about the branch.
    /// - Throws: ``LoreError`` if the library can't read the branch,
    ///   such as ``LoreError/Code/notFound``
    ///   for a branch that doesn't exist or is archived.
    public func branchInfo(named name: String? = nil, inLinkAt link: String? = nil) async throws -> BranchInfo {
        let branches = try await perform(
            lore_branch_info_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_info_args_t>, arena) in
                arguments.pointee.branch = arena.string(name)
                arguments.pointee.link = arena.string(link)
            },
            transform: { event -> BranchInfo? in
                guard event.pointee.tag == LORE_EVENT_BRANCH_INFO.rawValue else {
                    return nil
                }
                let data = event.pointee.branch_info
                guard let id = BranchID(data.id) else {
                    return nil
                }
                return BranchInfo(
                    id: id,
                    name: String(data.name),
                    category: String(data.category),
                    latestRevision: RevisionID(data.latest),
                    remoteLatestRevision: RevisionID(data.latest_remote),
                    parentID: BranchID(data.parent),
                    branchPoint: RevisionID(data.branch_point),
                    creator: String(data.creator),
                    creationDate: Date(millisecondsSince1970: data.created),
                    isArchived: Bool(data.archived)
                )
            }
        )
        guard let branch = branches.last else {
            throw LoreError.missingEvent("the branch")
        }
        return branch
    }

    /// Archives a branch,
    /// which removes it from ``branches(includingArchived:)``
    /// unless you include archived branches.
    ///
    /// Unless the repository is offline,
    /// the branch is also archived on the server.
    ///
    /// - Parameters:
    ///   - name: The name of the branch.
    ///   - includingLinks: Whether to also archive the branch
    ///     in every linked repository.
    ///   - includingLayers: Whether to also archive the branch
    ///     in the repository of every layer.
    /// - Throws: ``LoreError`` if the library can't archive the branch,
    ///   such as ``LoreError/Code/branchNotFound``.
    ///   The library refuses to archive the current branch
    ///   and reports that with ``LoreError/Code/branchNotFound``.
    ///   Unless the repository is offline,
    ///   Lore 0.12.0 also reports ``LoreError/Code/branchNotFound``
    ///   for a branch that you never switched to,
    ///   with or without `includingLinks`.
    public func archiveBranch(
        named name: String,
        includingLinks: Bool = false,
        includingLayers: Bool = false
    ) async throws {
        _ = try await perform(
            lore_branch_archive_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_archive_args_t>, arena) in
                arguments.pointee.branch = arena.string(name)
                arguments.pointee.include_links = UInt8(includingLinks)
                arguments.pointee.include_layers = UInt8(includingLayers)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Protects a branch from pushes.
    ///
    /// The server refuses to accept a push to a protected branch
    /// and reports that with ``LoreError/Code/notAuthorized``;
    /// you can still commit to the branch locally.
    /// The protection is recorded as the `protect` value
    /// of ``branchMetadata(of:)``.
    ///
    /// - Parameter name: The name of the branch.
    /// - Throws: ``LoreError`` if the library can't protect the branch,
    ///   such as ``LoreError/Code/branchNotFound``.
    public func protectBranch(named name: String) async throws {
        _ = try await perform(
            lore_branch_protect_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_protect_args_t>, arena) in
                arguments.pointee.branch = arena.string(name)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Removes the protection from a branch.
    ///
    /// - Parameter name: The name of the branch.
    /// - Throws: ``LoreError`` if the library can't unprotect the branch,
    ///   such as ``LoreError/Code/branchNotFound``.
    public func unprotectBranch(named name: String) async throws {
        _ = try await perform(
            lore_branch_unprotect_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_unprotect_args_t>, arena) in
                arguments.pointee.branch = arena.string(name)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Moves the latest revision of a branch to another revision.
    ///
    /// Resetting the current branch also syncs the working directory
    /// to the revision.
    /// The revisions after it stay in the repository,
    /// and ``latestRevisions(on:limit:)`` lists them.
    ///
    /// - Parameters:
    ///   - name: The name of the branch,
    ///     or `nil` for the current branch.
    ///   - revision: The revision to reset the branch to.
    /// - Returns: The new latest revision of the branch.
    /// - Throws: ``LoreError`` if the library can't reset the branch,
    ///   such as ``LoreError/Code/revisionNotFound``.
    @discardableResult
    public func resetBranch(named name: String? = nil, to revision: RevisionSpecifier) async throws -> RevisionID? {
        let revisions = try await perform(
            lore_branch_reset_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_reset_args_t>, arena) in
                arguments.pointee.branch = arena.string(name)
                arguments.pointee.revision = arena.string(revision.rawValue)
            },
            transform: { event -> RevisionID?? in
                guard event.pointee.tag == LORE_EVENT_BRANCH_RESET.rawValue else {
                    return nil
                }
                return .some(RevisionID(event.pointee.branch_reset.revision))
            }
        )
        return revisions.last ?? nil
    }

    /// Lists the revisions that have been the latest revision of a branch,
    /// newest first.
    ///
    /// Each commit and each ``resetBranch(named:to:)`` adds an entry,
    /// so the list shows the revisions that a reset moved the branch away from.
    ///
    /// - Parameters:
    ///   - branch: The name of the branch,
    ///     or `nil` for the current branch.
    ///   - limit: The maximum number of revisions to list,
    ///     or `nil` for the library's default of 30.
    /// - Returns: The revisions.
    /// - Throws: ``LoreError`` if the library can't list the revisions,
    ///   or with ``LoreError/Code/invalidArguments``
    ///   if `limit` is less than 1.
    public func latestRevisions(on branch: String? = nil, limit: Int? = nil) async throws -> [RevisionID] {
        // The library reads a limit of 0 as its default.
        if let limit, limit < 1 {
            throw LoreError(code: .invalidArguments, message: "The limit must be at least 1, not \(limit).")
        }
        return try await perform(
            lore_branch_latest_list_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_latest_list_args_t>, arena) in
                arguments.pointee.branch = arena.string(branch)
                arguments.pointee.limit = UInt32(clamping: limit ?? 0)
            },
            transform: { event -> RevisionID? in
                guard event.pointee.tag == LORE_EVENT_BRANCH_LATEST_LIST_ENTRY.rawValue else {
                    return nil
                }
                return RevisionID(event.pointee.branch_latest_list_entry.revision)
            }
        )
    }
}

// MARK: - Branch metadata

extension Repository {
    /// Returns the metadata value of a branch for a key.
    ///
    /// - Parameters:
    ///   - key: The metadata key.
    ///   - branch: The name of the branch,
    ///     or `nil` for the current branch.
    /// - Returns: The value, or `nil` if the branch has no value for the key.
    /// - Throws: ``LoreError`` if the library can't read the metadata.
    public func branchMetadata(forKey key: String, of branch: String? = nil) async throws -> MetadataValue? {
        try await metadataEntries(
            lore_branch_metadata_get_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_metadata_get_args_t>, arena) in
                arguments.pointee.branch = arena.string(branch)
                arguments.pointee.key = arena.string(key)
            }
        )[key]
    }

    /// Returns the metadata of a branch.
    ///
    /// The metadata includes values that Lore records for every branch,
    /// such as `name`, `creator`, and `protect`.
    ///
    /// - Parameter branch: The name of the branch,
    ///   or `nil` for the current branch.
    /// - Returns: The metadata values, by key.
    /// - Throws: ``LoreError`` if the library can't read the metadata.
    public func branchMetadata(of branch: String? = nil) async throws -> [String: MetadataValue] {
        try await metadataEntries(
            lore_branch_metadata_get_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_metadata_get_args_t>, arena) in
                arguments.pointee.branch = arena.string(branch)
            }
        )
    }

    /// Sets metadata values on a branch.
    ///
    /// Branch metadata is held on the server,
    /// so the repository must not be offline.
    ///
    /// - Parameters:
    ///   - values: The values to set, by key.
    ///   - branch: The name of the branch,
    ///     or `nil` for the current branch.
    /// - Throws: ``LoreError`` if the library can't set the metadata,
    ///   such as ``LoreError/Code/noRemote``,
    ///   or with ``LoreError/Code/notSupported``
    ///   for a ``MetadataValue/binary(_:)``
    ///   or ``MetadataValue/address(_:)`` value,
    ///   which the binding can't set.
    public func setBranchMetadata(_ values: [String: MetadataValue], of branch: String? = nil) async throws {
        let metadata = try EncodedMetadata(values)
        _ = try await perform(
            lore_branch_metadata_set_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_metadata_set_args_t>, arena) in
                arguments.pointee.branch = arena.string(branch)
                arguments.pointee.keys = arena.strings(metadata.keys)
                arguments.pointee.values = arena.strings(metadata.texts)
                arguments.pointee.formats = metadata.formats(in: arena)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Removes metadata values from a branch.
    ///
    /// Branch metadata is held on the server,
    /// so the repository must not be offline.
    ///
    /// - Parameters:
    ///   - keys: The keys to remove,
    ///     or an empty array for every value that you set.
    ///   - branch: The name of the branch,
    ///     or `nil` for the current branch.
    /// - Throws: ``LoreError`` if the library can't clear the metadata,
    ///   such as ``LoreError/Code/noRemote``.
    public func clearBranchMetadata(keys: [String] = [], of branch: String? = nil) async throws {
        _ = try await perform(
            lore_branch_metadata_clear_async,
            configure: { (arguments: UnsafeMutablePointer<lore_branch_metadata_clear_args_t>, arena) in
                arguments.pointee.branch = arena.string(branch)
                arguments.pointee.keys = arena.strings(keys)
            },
            transform: { _ -> Never? in nil }
        )
    }
}
