import CLore

/// A dependency of one file on another.
public struct Dependency: Sendable, Hashable {
    /// The path of the file that has the dependency.
    public var path: String

    /// The path of the file that it depends on,
    /// or that depends on it when you list dependents.
    public var dependency: String

    /// The tags on the dependency.
    public var tags: [String]

    /// The depth of the dependency in the traversal:
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

    /// Lists the dependencies of files.
    ///
    /// - Parameters:
    ///   - paths: The paths of the files, relative to the repository directory.
    ///   - revision: The revision to read,
    ///     or `nil` for the current state of the working directory.
    ///   - recursive: Whether to follow dependencies of dependencies.
    ///   - dependents: Whether to list the files that depend on `paths`
    ///     instead of the files that `paths` depend on.
    ///   - tags: Tags to filter the dependencies by,
    ///     or an empty array for every dependency.
    ///   - depthLimit: The maximum depth of a recursive listing,
    ///     or `nil` for no limit.
    /// - Returns: The dependencies, grouped by file in the order of `paths`.
    /// - Throws: ``LoreError`` if the library can't list the dependencies.
    public func dependencies(
        of paths: [String],
        revision: String? = nil,
        recursive: Bool = false,
        dependents: Bool = false,
        tags: [String] = [],
        depthLimit: Int? = nil
    ) async throws -> [Dependency] {
        let events = try await perform(
            lore_file_dependency_list_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_dependency_list_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
                arguments.pointee.revision = arena.string(revision)
                arguments.pointee.recursive = UInt8(recursive)
                arguments.pointee.reverse = UInt8(dependents)
                arguments.pointee.tags = arena.strings(tags)
                arguments.pointee.depth_limit = UInt32(clamping: depthLimit ?? 0)
            },
            transform: DependencyListEvent.init
        )
        // Each entry belongs to the file that the last FILE event named.
        var path = ""
        var dependencies: [Dependency] = []
        for event in events {
            switch event {
            case .file(let file):
                path = file
            case .entry(let dependency, let tags, let depth):
                dependencies.append(
                    Dependency(path: path, dependency: dependency, tags: tags, depth: depth)
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
