import CLore

extension Repository {
    /// Marks files as changed,
    /// so that a status that doesn't scan reports them.
    ///
    /// A status without a scan reports only the files
    /// that the repository already marks as changed,
    /// so an app that watches the working directory
    /// can mark the files that change
    /// and then call ``status(of:scanning:)`` with `scanning` set to `false`
    /// instead of scanning every file.
    ///
    /// Lore checks each path in the working directory and the current revision:
    /// a file in both is modified,
    /// a file only in the working directory is added,
    /// and a file only in the current revision is deleted.
    /// It ignores a path that is in neither,
    /// a path outside the repository directory,
    /// and a path in the repository's `.lore` directory.
    /// Marking a file doesn't stage it;
    /// ``stage(_:scanning:)`` it to commit its content.
    ///
    /// - Parameter paths: The paths of the files, relative to the repository directory.
    /// - Throws: ``LoreError`` if the library can't mark the files.
    public func markDirty(_ paths: [String]) async throws {
        _ = try await perform(
            lore_file_dirty_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_dirty_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Records that a file moved,
    /// without checking the working directory.
    ///
    /// Lore moves the file's entry in the staged changes,
    /// so a status reports a move from `source`
    /// instead of a deletion and an addition.
    /// The status reports the move as unstaged,
    /// but the next commit records it.
    /// Move the file in the working directory yourself.
    ///
    /// - Parameters:
    ///   - source: The path that the file moved from,
    ///     relative to the repository directory.
    ///   - destination: The path that the file moved to,
    ///     relative to the repository directory.
    /// - Throws: ``LoreError`` if the library can't record the move,
    ///   such as ``LoreError/Code/nodeNotFound``
    ///   for a source that the repository doesn't track.
    public func markMoved(from source: String, to destination: String) async throws {
        _ = try await perform(
            lore_file_dirty_move_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_dirty_move_args_t>, arena) in
                arguments.pointee.from_path = arena.string(source)
                arguments.pointee.to_path = arena.string(destination)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Records that a file was copied,
    /// without checking the working directory.
    ///
    /// Lore adds an entry for `destination` with the content of `source`
    /// to the staged changes,
    /// and a status reports `destination` as an added file.
    /// Copy the file in the working directory yourself.
    ///
    /// - Parameters:
    ///   - source: The path of the file that was copied,
    ///     relative to the repository directory.
    ///   - destination: The path of the copy,
    ///     relative to the repository directory.
    /// - Throws: ``LoreError`` if the library can't record the copy,
    ///   such as ``LoreError/Code/nodeNotFound``
    ///   for a source that the repository doesn't track.
    public func markCopied(from source: String, to destination: String) async throws {
        _ = try await perform(
            lore_file_dirty_copy_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_dirty_copy_args_t>, arena) in
                arguments.pointee.from_path = arena.string(source)
                arguments.pointee.to_path = arena.string(destination)
            },
            transform: { _ -> Never? in nil }
        )
    }
}
