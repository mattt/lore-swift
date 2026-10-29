import CLore
import Foundation

/// The content hash of a file.
public struct FileHash: Sendable, Hashable {
    /// The path of the file, as you passed it.
    public var path: String

    /// The size of the file, in bytes.
    public var size: Int

    /// The 32 bytes of the content hash.
    ///
    /// It's the ``ContentAddress/hash`` of the address
    /// under which a repository stores the same content.
    public var hash: [UInt8]
}

/// How a repository's store holds a piece of content.
public struct StoredContent: Sendable, Hashable {
    /// The address of the content.
    public var address: ContentAddress

    /// The size of the content, in bytes.
    public var size: Int

    /// The size of the stored payload, in bytes,
    /// which is smaller than ``size`` when the store compresses the content.
    public var payloadSize: Int
}

/// The content that an obliteration removed.
public struct ObliterationResult: Sendable, Hashable {
    /// The address of the content.
    public var address: ContentAddress

    /// The number of fragments removed from the local store.
    public var fragmentCount: Int

    /// The number of payloads removed from the local store.
    public var payloadCount: Int
}

extension Repository {
    /// Computes the content hashes of files.
    ///
    /// Compare a hash with the ``ContentAddress/hash`` of
    /// ``storedContent(of:)`` to tell whether a file holds the content
    /// that the repository stores for it.
    ///
    /// - Parameter paths: The paths of the files, relative to the repository directory.
    ///   An absolute path can name any file, including one outside the repository.
    /// - Returns: The hashes of the files, in the order of `paths`.
    /// - Throws: ``LoreError`` if the library can't hash a file,
    ///   such as ``LoreError/Code/invalidArguments``
    ///   for a path that doesn't exist or isn't a file.
    public func contentHashes(of paths: [String]) async throws -> [FileHash] {
        try await perform(
            lore_file_hash_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_hash_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
            },
            transform: { event -> FileHash? in
                guard event.pointee.tag == LORE_EVENT_FILE_HASH.rawValue else {
                    return nil
                }
                let data = event.pointee.file_hash
                return FileHash(
                    path: String(data.path),
                    size: Int(clamping: data.size),
                    hash: tupleBytes(data.hash.data)
                )
            }
        )
    }

    /// Returns how the repository's store holds the content of a file.
    ///
    /// The content is that of the version of the file in the current revision,
    /// not the file in the working directory.
    /// In Lore 0.11.0,
    /// that's also the case for a file whose change is staged.
    ///
    /// - Parameter path: The path of the file, relative to the repository directory.
    /// - Returns: The stored content,
    ///   or `nil` if the local store doesn't hold it,
    ///   such as after ``obliterate(_:)``.
    /// - Throws: ``LoreError`` if the library can't read the store,
    ///   such as ``LoreError/Code/nodeNotFound``
    ///   for a path that the repository doesn't track.
    public func storedContent(of path: String) async throws -> StoredContent? {
        try await storedContent { arguments, arena in
            arguments.pointee.path = arena.string(path)
        }
    }

    /// Returns how the repository's store holds the content at an address.
    ///
    /// - Parameter address: The address of the content.
    /// - Returns: The stored content,
    ///   or `nil` if the local store doesn't hold content at the address.
    /// - Throws: ``LoreError`` if the library can't read the store.
    public func storedContent(at address: ContentAddress) async throws -> StoredContent? {
        try await storedContent { arguments, arena in
            arguments.pointee.address = arena.string(address.description)
        }
    }

    private func storedContent(
        configure: (UnsafeMutablePointer<lore_file_dump_args_t>, Arena) -> Void
    ) async throws -> StoredContent? {
        let results = try await perform(
            lore_file_dump_async,
            configure: configure,
            transform: { event -> StoredContent?? in
                guard event.pointee.tag == LORE_EVENT_FILE_DUMP.rawValue else {
                    return nil
                }
                let data = event.pointee.file_dump
                // The store reports which parts of the address it matched,
                // and 0 if it holds nothing there.
                guard data.match_made != 0 else {
                    return .some(nil)
                }
                return StoredContent(
                    address: ContentAddress(data.address),
                    size: Int(clamping: data.size_content),
                    payloadSize: Int(data.size_payload)
                )
            }
        )
        guard let result = results.last else {
            throw LoreError.missingEvent("the stored content")
        }
        return result
    }

    /// Writes the content of a file in a revision to another file.
    ///
    /// The method doesn't change the repository,
    /// so a destination inside the repository directory
    /// becomes a file that the repository doesn't track.
    ///
    /// - Parameters:
    ///   - path: The path of the file in the repository,
    ///     relative to the repository directory.
    ///   - revision: The revision to read,
    ///     or `nil` for the current revision.
    ///     In Lore 0.11.0,
    ///     `nil` reads the current revision's version
    ///     even for a file whose change is staged.
    ///   - destination: The path of the file to write,
    ///     relative to the repository directory unless it's absolute.
    ///   - replacingExistingFile: Whether to replace a file at `destination`.
    /// - Throws: ``LoreError`` if the library can't write the file,
    ///   such as ``LoreError/Code/fileNotFound``
    ///   for a path that the revision doesn't have,
    ///   ``LoreError/Code/revisionNotFound``,
    ///   ``LoreError/Code/invalidPath``
    ///   for a destination that is a directory,
    ///   or that is a file when `replacingExistingFile` is `false`,
    ///   or ``LoreError/Code/addressNotFound``
    ///   for content that ``obliterate(_:)`` removed.
    public func writeContents(
        of path: String,
        revision: RevisionSpecifier? = nil,
        to destination: String,
        replacingExistingFile: Bool = false
    ) async throws {
        try await writeContents(to: destination, replacingExistingFile: replacingExistingFile) { arguments, arena in
            arguments.pointee.path = arena.string(path)
            arguments.pointee.revision = arena.string(revision?.rawValue)
        }
    }

    /// Writes the content at an address in the repository's store to a file.
    ///
    /// - Parameters:
    ///   - address: The address of the content.
    ///   - destination: The path of the file to write,
    ///     relative to the repository directory unless it's absolute.
    ///   - replacingExistingFile: Whether to replace a file at `destination`.
    /// - Throws: ``LoreError`` if the library can't write the file,
    ///   such as ``LoreError/Code/addressNotFound``
    ///   or ``LoreError/Code/invalidPath``
    ///   for a destination that is a directory,
    ///   or that is a file when `replacingExistingFile` is `false`.
    public func writeContents(
        at address: ContentAddress,
        to destination: String,
        replacingExistingFile: Bool = false
    ) async throws {
        try await writeContents(to: destination, replacingExistingFile: replacingExistingFile) { arguments, arena in
            arguments.pointee.address = arena.string(address.description)
        }
    }

    private func writeContents(
        to destination: String,
        replacingExistingFile: Bool,
        configure: (UnsafeMutablePointer<lore_file_write_args_t>, Arena) -> Void
    ) async throws {
        // Lore 0.11.0 resolves a relative destination
        // against the current directory of the process
        // to decide whether the call writes inside the repository,
        // and rejects one inside the repository with error 19,
        // so the binding passes an absolute path.
        let directory = URL(fileURLWithPath: absolutePath, isDirectory: true)
        let destination = URL(fileURLWithPath: destination, relativeTo: directory).standardizedFileURL.path
        _ = try await perform(
            lore_file_write_async,
            force: replacingExistingFile,
            configure: { (arguments: UnsafeMutablePointer<lore_file_write_args_t>, arena) in
                configure(arguments, arena)
                arguments.pointee.output = arena.string(destination)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Permanently removes the stored content of a file
    /// from the repository's store and from the server,
    /// and deletes the file.
    ///
    /// Obliterating can't be undone.
    /// The library removes the content of the version of the file
    /// in the current revision from the local store,
    /// and from the server unless the repository is offline.
    /// In Lore 0.11.0,
    /// that's also the version it removes for a file whose change is staged.
    /// Every revision whose file has that content keeps its record of the file,
    /// but no longer has its content:
    /// reading the file at such a revision,
    /// or syncing or cloning such a revision,
    /// fails with ``LoreError/Code/addressNotFound``
    /// or ``LoreError/Code/internal``.
    /// Versions of the file with other content stay.
    ///
    /// The method also deletes the file from the working directory
    /// and stages its deletion,
    /// which replaces a staged change to the file.
    /// In Lore 0.11.0,
    /// committing that deletion fails with ``LoreError/Code/internal``;
    /// ``unstage(_:)`` and ``stage(_:scanning:)`` the path again first.
    ///
    /// - Parameter path: The path of the file, relative to the repository directory.
    /// - Returns: The address of the content that was removed,
    ///   and what the local store removed.
    /// - Throws: ``LoreError`` if the library can't obliterate the content,
    ///   such as ``LoreError/Code/fileNotFound``
    ///   for a path that the repository doesn't track.
    @discardableResult
    public func obliterate(_ path: String) async throws -> ObliterationResult {
        try await obliterate { arguments, arena in
            arguments.pointee.path = arena.string(path)
        }
    }

    /// Permanently removes the content at an address
    /// from the repository's store and from the server.
    ///
    /// Obliterating can't be undone.
    /// The library removes the content from the local store,
    /// and from the server unless the repository is offline.
    /// Every revision with a file that has the content
    /// keeps its record of the file,
    /// but no longer has its content:
    /// reading the file at such a revision,
    /// or syncing or cloning such a revision,
    /// fails with ``LoreError/Code/addressNotFound``
    /// or ``LoreError/Code/internal``.
    /// The method doesn't change the working directory or the staged changes.
    ///
    /// - Parameter address: The address of the content.
    /// - Returns: The address of the content that was removed,
    ///   and what the local store removed.
    /// - Throws: ``LoreError`` if the library can't obliterate the content.
    @discardableResult
    public func obliterate(contentAt address: ContentAddress) async throws -> ObliterationResult {
        try await obliterate { arguments, arena in
            arguments.pointee.address = arena.string(address.description)
        }
    }

    private func obliterate(
        configure: (UnsafeMutablePointer<lore_file_obliterate_args_t>, Arena) -> Void
    ) async throws -> ObliterationResult {
        let results = try await perform(
            lore_file_obliterate_async,
            configure: configure,
            transform: { event -> ObliterationResult? in
                guard event.pointee.tag == LORE_EVENT_FILE_OBLITERATE.rawValue else {
                    return nil
                }
                let data = event.pointee.file_obliterate
                return ObliterationResult(
                    address: ContentAddress(data.address),
                    fragmentCount: Int(data.num_fragments),
                    payloadCount: Int(data.num_payloads)
                )
            }
        )
        guard let result = results.last else {
            throw LoreError.missingEvent("the obliterated content")
        }
        return result
    }
}
