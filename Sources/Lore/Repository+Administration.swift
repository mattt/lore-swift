import CLore
import Foundation

/// A repository that a server hosts.
public struct RemoteRepository: Sendable, Hashable, Identifiable {
    /// The identifier of the repository.
    public var id: RepositoryID

    /// The name of the repository.
    public var name: String
}

extension Repository {
    /// Returns the repositories that a server hosts.
    ///
    /// The server lists the repositories that the caller may access.
    ///
    /// - Parameters:
    ///   - server: The URL of the server,
    ///     such as `lore://127.0.0.1:41337`.
    ///   - options: The options for the call,
    ///     such as the identity to connect with.
    /// - Returns: The repositories.
    /// - Throws: ``LoreError`` if the library can't list the repositories,
    ///   such as ``LoreError/Code/invalidArguments`` for an empty server URL.
    public static func repositories(
        on server: String,
        options: Options = Options()
    ) async throws -> [RemoteRepository] {
        if server.isEmpty {
            throw LoreError(code: .invalidArguments, message: "The server URL is empty.")
        }
        return try await Repository(path: "", options: options).perform(
            lore_repository_list_async,
            configure: { (arguments: UnsafeMutablePointer<lore_repository_list_args_t>, arena) in
                arguments.pointee.url = arena.string(server)
            },
            transform: { event -> RemoteRepository? in
                guard event.pointee.tag == LORE_EVENT_REPOSITORY_LIST_ENTRY.rawValue else {
                    return nil
                }
                let data = event.pointee.repository_list_entry
                guard let id = RepositoryID(data.id) else {
                    return nil
                }
                return RemoteRepository(id: id, name: String(data.name))
            }
        )
    }

    /// Deletes a repository from its server.
    ///
    /// The server deletes the repository for every user,
    /// and the library offers no way to undo it.
    /// Afterward, the server doesn't list the repository
    /// or find it by name,
    /// so a clone of it fails with ``LoreError/Code/notFound``.
    /// Checkouts of the repository keep their files and revisions.
    /// A server lets the user who created the repository delete it,
    /// and a user that it grants the `owner` or `admin` permission.
    ///
    /// - Parameters:
    ///   - url: The URL of the repository,
    ///     such as `lore://127.0.0.1:41337/my-project`.
    ///   - options: The options for the call,
    ///     such as the identity to connect with.
    /// - Throws: ``LoreError`` if the library can't delete the repository,
    ///   such as ``LoreError/Code/notAuthorized`` for a user who may not delete it,
    ///   or ``LoreError/Code/invalidArguments`` for a URL without a scheme.
    public static func deleteFromServer(_ url: String, options: Options = Options()) async throws {
        guard url.contains("://") else {
            // The library resolves a name without a scheme
            // against the repository in the current directory of the process.
            throw LoreError(code: .invalidArguments, message: "The repository URL has no scheme: \(url)")
        }
        try await Repository(path: "", options: options).deleteFromServer(nameOrURL: url)
    }

    /// Deletes this repository from its server.
    ///
    /// See ``deleteFromServer(_:options:)``.
    /// The method doesn't change the repository directory.
    ///
    /// - Throws: ``LoreError`` if the library can't delete the repository,
    ///   such as ``LoreError/Code/notAuthorized`` for a user who may not delete it,
    ///   or ``LoreError/Code/noRemote`` for a repository without a server.
    public func deleteFromServer() async throws {
        let state = try await state()
        // The library resolves an identifier against this repository's server.
        try await deleteFromServer(nameOrURL: state.repositoryID.description)
    }

    private func deleteFromServer(nameOrURL: String) async throws {
        _ = try await perform(
            lore_repository_delete_async,
            configure: { (arguments: UnsafeMutablePointer<lore_repository_delete_args_t>, arena) in
                arguments.pointee.repository_url = arena.string(nameOrURL)
            },
            transform: { _ -> Never? in nil }
        )
    }
}
