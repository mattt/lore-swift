import CLore
import Foundation

/// Information about a repository on a server.
public struct RepositoryInfo: Sendable, Hashable, Identifiable {
    /// The identifier of the repository.
    public var id: RepositoryID

    /// The URL of the server.
    public var remote: String

    /// The name of the repository.
    public var name: String

    /// The description of the repository.
    public var description: String

    /// The identifier of the default branch.
    public var defaultBranchID: BranchID?

    /// The name of the default branch.
    public var defaultBranchName: String

    /// The identifier of the user who created the repository.
    public var creator: String

    /// The time the repository was created.
    public var creationDate: Date
}

extension Repository {
    /// Returns information about the repository from its server.
    ///
    /// - Returns: Information about the repository.
    /// - Throws: ``LoreError`` if the library can't read the information,
    ///   such as ``LoreError/Code/noRemote`` for an offline repository.
    public func info() async throws -> RepositoryInfo {
        let repositories = try await perform(
            lore_repository_info_async,
            transform: { event -> RepositoryInfo? in
                guard event.pointee.tag == LORE_EVENT_REPOSITORY_DATA.rawValue else {
                    return nil
                }
                let data = event.pointee.repository_data
                guard let id = RepositoryID(data.id) else {
                    return nil
                }
                return RepositoryInfo(
                    id: id,
                    remote: String(data.remote_url),
                    name: String(data.name),
                    description: String(data.description),
                    defaultBranchID: BranchID(data.default_branch),
                    defaultBranchName: String(data.default_branch_name),
                    creator: String(data.creator),
                    creationDate: Date(millisecondsSince1970: data.created)
                )
            }
        )
        guard let repository = repositories.last else {
            throw LoreError.missingEvent("the repository")
        }
        return repository
    }
}

// MARK: - Repository metadata

extension Repository {
    /// Returns the metadata value of the repository for a key.
    ///
    /// - Parameter key: The metadata key.
    /// - Returns: The value, or `nil` if the repository has no value for the key.
    /// - Throws: ``LoreError`` if the library can't read the metadata.
    public func repositoryMetadata(forKey key: String) async throws -> MetadataValue? {
        try await metadataEntries(
            lore_repository_metadata_get_async,
            configure: { (arguments: UnsafeMutablePointer<lore_repository_metadata_get_args_t>, arena) in
                arguments.pointee.key = arena.string(key)
            }
        )[key]
    }

    /// Returns the metadata of the repository.
    ///
    /// The metadata includes values that Lore records for every repository,
    /// such as `name`, `description`, and `default-branch-name`.
    ///
    /// - Returns: The metadata values, by key.
    /// - Throws: ``LoreError`` if the library can't read the metadata.
    public func repositoryMetadata() async throws -> [String: MetadataValue] {
        try await metadataEntries(
            lore_repository_metadata_get_async,
            configure: { (_: UnsafeMutablePointer<lore_repository_metadata_get_args_t>, _) in }
        )
    }

    /// Sets metadata values on the repository.
    ///
    /// Repository metadata is held on the server,
    /// so the repository must not be offline.
    ///
    /// - Parameter values: The values to set, by key.
    /// - Throws: ``LoreError`` if the library can't set the metadata,
    ///   such as ``LoreError/Code/noRemote``,
    ///   or with ``LoreError/Code/notSupported``
    ///   for a ``MetadataValue/binary(_:)``
    ///   or ``MetadataValue/address(hash:context:)`` value,
    ///   which the binding can't set.
    public func setRepositoryMetadata(_ values: [String: MetadataValue]) async throws {
        let metadata = try EncodedMetadata(values)
        _ = try await perform(
            lore_repository_metadata_set_async,
            configure: { (arguments: UnsafeMutablePointer<lore_repository_metadata_set_args_t>, arena) in
                arguments.pointee.keys = arena.strings(metadata.keys)
                arguments.pointee.values = arena.strings(metadata.texts)
                arguments.pointee.formats = metadata.formats(in: arena)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Removes metadata values from the repository.
    ///
    /// Repository metadata is held on the server,
    /// so the repository must not be offline.
    ///
    /// - Parameter keys: The keys to remove,
    ///   or an empty array for every value that you set.
    /// - Throws: ``LoreError`` if the library can't clear the metadata,
    ///   such as ``LoreError/Code/noRemote``.
    public func clearRepositoryMetadata(keys: [String] = []) async throws {
        _ = try await perform(
            lore_repository_metadata_clear_async,
            configure: { (arguments: UnsafeMutablePointer<lore_repository_metadata_clear_args_t>, arena) in
                arguments.pointee.keys = arena.strings(keys)
            },
            transform: { _ -> Never? in nil }
        )
    }
}
