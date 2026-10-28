import CLore

/// A dependency of one file on another.
public struct Dependency: Sendable, Hashable {
    /// The path of the file that has the dependency.
    public var path: String

    /// The path of the file that ``path`` depends on,
    /// directly or through other files.
    public var dependency: String

    /// The tags on the dependency.
    public var tags: [String]

    /// The depth of the dependency in the listing:
    /// 0 for a direct dependency.
    public var depth: Int
}

extension Repository {
    /// Records that a file depends on other files.
    ///
    /// The dependencies become part of the file's staged state.
    ///
    /// - Parameters:
    ///   - dependencies: The paths of the files that `path` depends on,
    ///     relative to the repository directory.
    ///   - path: The path of the file that has the dependencies.
    ///   - tags: Tags to apply to each dependency.
    ///   - allowingCycles: Whether to skip cycle detection.
    /// - Returns: The number of dependencies that the library added.
    /// - Throws: ``LoreError`` if the library can't add the dependencies.
    @discardableResult
    public func addDependencies(
        _ dependencies: [String],
        to path: String,
        tags: [String] = [],
        allowingCycles: Bool = false
    ) async throws -> Int {
        let counts = try await perform(
            lore_file_dependency_add_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_dependency_add_args_t>, arena) in
                arguments.pointee.paths = arena.strings([path])
                arguments.pointee.dependencies = arena.strings(dependencies)
                arguments.pointee.tags = arena.strings(dependencies.flatMap { _ in tags })
                let dependencyCounts = arena.array([UInt32(dependencies.count)])
                arguments.pointee.dep_counts = lore_uint32_array_t(
                    ptr: dependencyCounts.pointer,
                    count: UInt(dependencyCounts.count)
                )
                let tagCounts = arena.array(dependencies.map { _ in UInt32(tags.count) })
                arguments.pointee.tag_counts = lore_uint32_array_t(
                    ptr: tagCounts.pointer,
                    count: UInt(tagCounts.count)
                )
                arguments.pointee.force = UInt8(allowingCycles)
            },
            transform: { event -> Int? in
                guard event.pointee.tag == LORE_EVENT_FILE_DEPENDENCY_ADD_END.rawValue else {
                    return nil
                }
                return Int(event.pointee.file_dependency_add_end.added_count)
            }
        )
        return counts.last ?? 0
    }

    /// Removes the records that a file depends on other files.
    ///
    /// The removal becomes part of the file's staged state.
    ///
    /// - Parameters:
    ///   - dependencies: The paths of the files that `path` no longer depends on,
    ///     relative to the repository directory.
    ///   - path: The path of the file that has the dependencies.
    /// - Returns: The number of dependencies that the library removed.
    /// - Throws: ``LoreError`` if the library can't remove the dependencies.
    @discardableResult
    public func removeDependencies(_ dependencies: [String], from path: String) async throws -> Int {
        let counts = try await perform(
            lore_file_dependency_remove_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_dependency_remove_args_t>, arena) in
                arguments.pointee.paths = arena.strings([path])
                arguments.pointee.dependencies = arena.strings(dependencies)
                let dependencyCounts = arena.array([UInt32(dependencies.count)])
                arguments.pointee.dep_counts = lore_uint32_array_t(
                    ptr: dependencyCounts.pointer,
                    count: UInt(dependencyCounts.count)
                )
                let tagCounts = arena.array(dependencies.map { _ in UInt32(0) })
                arguments.pointee.tag_counts = lore_uint32_array_t(
                    ptr: tagCounts.pointer,
                    count: UInt(tagCounts.count)
                )
            },
            transform: { event -> Int? in
                guard event.pointee.tag == LORE_EVENT_FILE_DEPENDENCY_REMOVE_END.rawValue else {
                    return nil
                }
                return Int(clamping: event.pointee.file_dependency_remove_end.removed_count)
            }
        )
        return counts.last ?? 0
    }

    /// Lists the files that files depend on.
    ///
    /// - Parameters:
    ///   - paths: The paths of the files, relative to the repository directory.
    ///   - revision: The revision to read,
    ///     or `nil` for the current state of the working directory.
    ///   - recursive: Whether to follow dependencies of dependencies.
    ///   - tags: Tags to filter the dependencies by,
    ///     or an empty array for every dependency.
    ///   - depthLimit: The number of levels that a recursive listing follows,
    ///     such as 1 for direct dependencies only,
    ///     or `nil` for no limit.
    /// - Returns: The dependencies, grouped by file in the order of `paths`.
    ///   The ``Dependency/path`` of each is the file in `paths`.
    /// - Throws: ``LoreError`` if the library can't list the dependencies,
    ///   or with ``LoreError/Code/invalidArguments``
    ///   if `depthLimit` is less than 1.
    public func dependencies(
        of paths: [String],
        revision: RevisionSpecifier? = nil,
        recursive: Bool = false,
        tags: [String] = [],
        depthLimit: Int? = nil
    ) async throws -> [Dependency] {
        try await listDependencies(
            of: paths,
            revision: revision,
            recursive: recursive,
            dependents: false,
            tags: tags,
            depthLimit: depthLimit
        )
    }

    /// Lists the files that depend on files.
    ///
    /// - Parameters:
    ///   - paths: The paths of the files, relative to the repository directory.
    ///   - revision: The revision to read,
    ///     or `nil` for the current state of the working directory.
    ///   - recursive: Whether to follow dependents of dependents.
    ///   - tags: Tags to filter the dependencies by,
    ///     or an empty array for every dependency.
    ///   - depthLimit: The number of levels that a recursive listing follows,
    ///     such as 1 for direct dependents only,
    ///     or `nil` for no limit.
    /// - Returns: The dependencies, grouped by file in the order of `paths`.
    ///   The ``Dependency/dependency`` of each is the file in `paths`.
    /// - Throws: ``LoreError`` if the library can't list the dependents,
    ///   or with ``LoreError/Code/invalidArguments``
    ///   if `depthLimit` is less than 1.
    public func dependents(
        of paths: [String],
        revision: RevisionSpecifier? = nil,
        recursive: Bool = false,
        tags: [String] = [],
        depthLimit: Int? = nil
    ) async throws -> [Dependency] {
        try await listDependencies(
            of: paths,
            revision: revision,
            recursive: recursive,
            dependents: true,
            tags: tags,
            depthLimit: depthLimit
        )
    }

    private func listDependencies(
        of paths: [String],
        revision: RevisionSpecifier?,
        recursive: Bool,
        dependents: Bool,
        tags: [String],
        depthLimit: Int?
    ) async throws -> [Dependency] {
        // The library reads a limit of 0 as no limit.
        if let depthLimit, depthLimit < 1 {
            throw LoreError(
                code: .invalidArguments,
                message: "The depth limit must be at least 1, not \(depthLimit)."
            )
        }
        let events = try await perform(
            lore_file_dependency_list_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_dependency_list_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
                arguments.pointee.revision = arena.string(revision?.rawValue)
                arguments.pointee.recursive = UInt8(recursive)
                arguments.pointee.reverse = UInt8(dependents)
                arguments.pointee.tags = arena.strings(tags)
                arguments.pointee.depth_limit = UInt32(clamping: depthLimit ?? 0)
            },
            transform: DependencyListEvent.init
        )
        // Each entry belongs to the file that the last FILE event named.
        var file = ""
        var dependencies: [Dependency] = []
        for event in events {
            switch event {
            case .file(let path):
                file = path
            case .entry(let entry, let tags, let depth):
                dependencies.append(
                    Dependency(
                        path: dependents ? entry : file,
                        dependency: dependents ? file : entry,
                        tags: tags,
                        depth: depth
                    )
                )
            }
        }
        return dependencies
    }
}

/// An event of a dependency listing.
private enum DependencyListEvent: Sendable {
    case file(String)
    case entry(String, tags: [String], depth: Int)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_FILE_DEPENDENCY_LIST_FILE.rawValue:
            self = .file(String(event.pointee.file_dependency_list_file.path))
        case LORE_EVENT_FILE_DEPENDENCY_LIST_ENTRY.rawValue:
            let data = event.pointee.file_dependency_list_entry
            self = .entry(String(data.path), tags: [String](data.tags), depth: Int(data.depth))
        default:
            return nil
        }
    }
}
