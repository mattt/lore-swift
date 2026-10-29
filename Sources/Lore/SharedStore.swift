import CLore
import Foundation

/// A store that several checkouts of the repositories on one server share,
/// so that content that they have in common is stored once on this computer.
///
/// A shared store belongs to one server.
/// It's a directory named `shared_store`
/// inside a directory for the server
/// that the library names after the server's URL without its scheme,
/// with `_` for each `:` and `/`,
/// such as `stores/127.0.0.1_41337/shared_store`
/// for a store that ``create(for:in:makingDefault:options:)`` creates in `stores`.
/// The library records every shared store that it creates
/// in a registry in the user's Lore data directory,
/// and the store that it uses by default for each server
/// in the user's global Lore configuration,
/// `config.toml` in ``Library/userDirectory``.
/// When `LORE_GLOBAL_PATH` is set in the environment,
/// the registry and the configuration are in its `data` and `config` subdirectories.
///
/// Pass ``Repository/StoreLocation/shared(in:)``
/// to ``Repository/create(at:name:description:store:options:)``
/// or ``Repository/clone(from:to:revision:store:options:)``
/// to make a checkout that uses a shared store.
public struct SharedStore: Sendable, Hashable {
    /// A checkout that uses a shared store.
    public struct Instance: Sendable, Hashable, Identifiable {
        /// The identifier of the instance.
        public var id: InstanceID

        /// The path of the checkout that the store records.
        public var path: String
    }

    /// The URL of the server that the store belongs to,
    /// such as `lore://127.0.0.1:41337`,
    /// or an empty string for the store of offline repositories.
    public var remoteURL: String

    /// The path of the store's `shared_store` directory.
    ///
    /// Pass the directory two levels up,
    /// or one level up for the store of offline repositories,
    /// to ``Repository/StoreLocation/shared(in:)``.
    public var path: String

    /// The checkouts that use the store,
    /// if you asked ``all(includingInstances:)`` for them.
    public var instances: [Instance]
}

extension SharedStore {
    /// The shared store settings in the user's global Lore configuration.
    public struct Configuration: Sendable, Hashable {
        /// The shared store that the library uses by default for a server.
        public struct DefaultStore: Sendable, Hashable {
            /// The URL of the server without its scheme,
            /// such as `127.0.0.1:41337`,
            /// as the configuration records it.
            public var server: String

            /// The path of the store's `shared_store` directory.
            public var path: String

            /// A Boolean value that indicates whether the store exists.
            public var exists: Bool
        }

        /// A Boolean value that indicates whether
        /// new checkouts use shared stores
        /// unless their ``Repository/StoreLocation`` says otherwise.
        public var isUsedAutomatically: Bool

        /// The default stores, one for each server that has one.
        public var defaultStores: [DefaultStore]
    }
}

extension SharedStore {
    /// Creates a shared store for a server.
    ///
    /// The library creates the directory for the server
    /// inside `directory`, with the store inside it,
    /// and records the store in its registry.
    /// Unless `options.isOffline` is `true`,
    /// it first connects to the server.
    ///
    /// - Parameters:
    ///   - remoteURL: The URL of the server,
    ///     such as `lore://127.0.0.1:41337`.
    ///   - directory: The directory to create the store in,
    ///     or `nil` for the default directory for the server.
    ///     A relative path is relative to the current directory of the process.
    ///   - makingDefault: Whether to record the store
    ///     as the server's default store in the user's global Lore configuration.
    ///   - options: The options for the call,
    ///     such as whether to connect to the server.
    /// - Returns: The new store.
    /// - Throws: ``LoreError`` if the library can't create the store,
    ///   such as when a store for the server already exists in the directory,
    ///   or ``LoreError/Code/invalidArguments`` for an empty server URL.
    @discardableResult
    public static func create(
        for remoteURL: String,
        in directory: String? = nil,
        makingDefault: Bool = false,
        options: Repository.Options = Repository.Options()
    ) async throws -> SharedStore {
        if remoteURL.isEmpty {
            throw LoreError(code: .invalidArguments, message: "The server URL is empty.")
        }
        // The library resolves a relative directory against the working directory of the call,
        // which is empty here.
        let directory = directory.map(Repository.absolutePath(of:))
        let paths = try await Repository(path: "", options: options).perform(
            lore_shared_store_create_async,
            configure: { (arguments: UnsafeMutablePointer<lore_shared_store_create_args_t>, arena) in
                arguments.pointee.remote_url = arena.string(remoteURL)
                arguments.pointee.path = arena.string(directory)
                arguments.pointee.make_default = UInt8(makingDefault)
            },
            transform: { event -> String? in
                guard event.pointee.tag == LORE_EVENT_SHARED_STORE_CREATE.rawValue else {
                    return nil
                }
                return String(event.pointee.shared_store_create.path)
            }
        )
        guard let path = paths.last else {
            throw LoreError.missingEvent("the shared store")
        }
        // The library records the URL without a trailing slash.
        var url = Substring(remoteURL)
        if url.hasSuffix("/") {
            url = url.dropLast()
        }
        return SharedStore(remoteURL: String(url), path: path, instances: [])
    }

    /// Returns the shared stores in the library's registry.
    ///
    /// - Parameter includingInstances: Whether to open each store
    ///   and read the checkouts that use it.
    /// - Returns: The stores.
    /// - Throws: ``LoreError`` if the library can't read the registry
    ///   or, with `includingInstances`, a store.
    public static func all(includingInstances: Bool = false) async throws -> [SharedStore] {
        let lists = try await context.perform(
            lore_shared_store_list_async,
            configure: { (arguments: UnsafeMutablePointer<lore_shared_store_list_args_t>, _) in
                arguments.pointee.include_instances = UInt8(includingInstances)
            },
            transform: { event -> [SharedStore]? in
                guard event.pointee.tag == LORE_EVENT_SHARED_STORE_LIST.rawValue else {
                    return nil
                }
                let stores = event.pointee.shared_store_list.stores
                guard let pointer = stores.ptr, stores.count > 0 else {
                    return []
                }
                return UnsafeBufferPointer(start: pointer, count: Int(stores.count)).map(SharedStore.init)
            }
        )
        guard let stores = lists.last else {
            throw LoreError.missingEvent("the shared stores")
        }
        return stores
    }

    /// Returns the shared store settings in the user's global Lore configuration.
    ///
    /// - Returns: The settings.
    /// - Throws: ``LoreError`` if the library can't read the configuration.
    public static func configuration() async throws -> Configuration {
        let configurations = try await context.perform(
            lore_shared_store_info_async,
            configure: { (_: UnsafeMutablePointer<lore_shared_store_info_args_t>, _) in },
            transform: { event -> Configuration? in
                guard event.pointee.tag == LORE_EVENT_SHARED_STORE_INFO.rawValue else {
                    return nil
                }
                return Configuration(event.pointee.shared_store_info)
            }
        )
        guard let configuration = configurations.last else {
            throw LoreError.missingEvent("the shared store configuration")
        }
        return configuration
    }

    /// Sets whether new checkouts use shared stores
    /// unless their ``Repository/StoreLocation`` says otherwise,
    /// for every process of the user.
    ///
    /// The method writes the setting to the user's global Lore configuration.
    /// It doesn't change existing checkouts.
    /// Pass `false` to restore the default.
    ///
    /// - Parameter enabled: Whether new checkouts use shared stores.
    /// - Throws: ``LoreError`` if the library can't write the configuration.
    public static func setUsedAutomatically(_ enabled: Bool) async throws {
        _ = try await context.perform(
            lore_shared_store_set_use_automatically_async,
            configure: {
                (arguments: UnsafeMutablePointer<lore_shared_store_set_use_automatically_args_t>, _) in
                arguments.pointee.enabled = UInt8(enabled)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// The context for calls that don't belong to a repository.
    private static var context: Repository {
        Repository(path: "")
    }
}

extension SharedStore {
    /// Copies an entry of a shared store list.
    fileprivate init(_ item: lore_shared_store_list_item_t) {
        let paths = [String](item.instance_paths)
        let ids =
            item.instance_ids.ptr.map {
                UnsafeBufferPointer(start: $0, count: Int(item.instance_ids.count)).map(InstanceID.init)
            } ?? []
        // The registry records the directory that holds the store.
        self.init(
            remoteURL: String(item.remote_url),
            path: URL(fileURLWithPath: String(item.store_path), isDirectory: true)
                .appending(path: "shared_store", directoryHint: .isDirectory)
                .standardizedFileURL.path,
            instances: zip(ids, paths).map { Instance(id: $0, path: $1) }
        )
    }
}

extension SharedStore.Configuration {
    /// Copies the data of a shared store info event.
    fileprivate init(_ data: lore_shared_store_info_event_data_t) {
        let remoteURLs = [String](data.remote_urls)
        let paths = [String](data.paths)
        let exists =
            data.exists.ptr.map { Array(UnsafeBufferPointer(start: $0, count: Int(data.exists.count))) } ?? []
        var defaultStores: [DefaultStore] = []
        for index in remoteURLs.indices where index < paths.count {
            defaultStores.append(
                DefaultStore(
                    server: remoteURLs[index],
                    path: paths[index],
                    exists: index < exists.count && exists[index] != 0
                )
            )
        }
        self.init(isUsedAutomatically: Bool(data.use_automatically), defaultStores: defaultStores)
    }
}

// MARK: - Repositories

extension Repository {
    /// Where a new checkout keeps the content of its repository.
    public enum StoreLocation: Sendable, Hashable {
        /// A shared store if ``SharedStore/setUsedAutomatically(_:)`` turned them on,
        /// in the server's default directory,
        /// and the checkout's own store otherwise.
        case automatic

        /// The checkout's own store, in its `.lore` directory.
        case local

        /// A shared store for the repository's server.
        ///
        /// The library creates the store if it doesn't exist.
        ///
        /// - Parameter directory: The directory that holds the store
        ///   inside a directory for the server,
        ///   as you pass it to ``SharedStore/create(for:in:makingDefault:options:)``,
        ///   or `nil` for the server's default store.
        ///   A relative path is relative to the current directory of the process.
        ///   The store of an offline repository,
        ///   which has no server,
        ///   is directly in the directory.
        ///   When the library creates a server's default store for `nil`,
        ///   it records the store as the server's default
        ///   in the user's global Lore configuration.
        case shared(in: String? = nil)
    }
}

extension Repository.StoreLocation {
    /// Sets the shared store fields of create or clone arguments.
    func configure(
        _ mode: inout lore_shared_store_mode_t,
        _ path: inout lore_string_t,
        in arena: Arena
    ) {
        switch self {
        case .automatic:
            mode = LORE_SHARED_STORE_MODE_INHERIT
        case .local:
            mode = LORE_SHARED_STORE_MODE_DISABLED
        case .shared(let directory):
            mode = LORE_SHARED_STORE_MODE_ENABLED
            // The library resolves a relative directory against the working directory of the call,
            // which is the new checkout.
            path = arena.string(directory.map(Repository.absolutePath(of:)))
        }
    }
}
