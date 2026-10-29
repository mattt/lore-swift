import Foundation
import Testing

@testable import Lore

/// Tests of shared stores that need no server.
///
/// The stores go in scratch directories.
/// Creating one records it in the registry in the scratch `HOME`,
/// which only ``SharedStore/all(includingInstances:)`` reads.
/// The tests that change the global configuration run in child processes
/// (exit tests) with a global configuration of their own,
/// because the settings change how other tests create repositories.
@Suite struct SharedStoreTests {
    let remote = "lore://shared-store.invalid:43000"
    let offline = Repository.Options(identity: "test@example.com", isOffline: true)

    @Test func createRecordsTheStoreInTheRegistry() async throws {
        let directory = temporaryPath("shared-stores")
        let store = try await SharedStore.create(for: remote, in: directory, options: offline)
        #expect(store.remote == remote)
        #expect(store.path == "\(directory)/shared-store.invalid_43000/shared_store")
        #expect(store.instances.isEmpty)
        #expect(FileManager.default.fileExists(atPath: "\(store.path)/shared_store.toml"))

        // The registry reports the store as `create` does.
        #expect(try await SharedStore.all().filter { $0.path.hasPrefix(directory) } == [store])
        let withInstances = try await SharedStore.all(includingInstances: true).filter { $0.path.hasPrefix(directory) }
        #expect(withInstances == [store])

        let again = await #expect(throws: LoreError.self) {
            try await SharedStore.create(for: remote, in: directory, options: offline)
        }
        #expect(again?.message.contains("Found existing shared store") == true)
        let empty = await #expect(throws: LoreError.self) {
            try await SharedStore.create(for: "", in: directory, options: offline)
        }
        #expect(empty?.code == .invalidArguments)
    }

    @Test func createResolvesARelativeDirectoryAgainstTheCurrentDirectory() async throws {
        let directory = temporaryPath("shared-stores")
        let relative = relativePath(to: directory)
        #expect(!relative.hasPrefix("/"))
        let store = try await SharedStore.create(for: remote, in: relative, options: offline)
        #expect(store.path == "\(directory)/shared-store.invalid_43000/shared_store")
        #expect(FileManager.default.fileExists(atPath: "\(store.path)/shared_store.toml"))
    }

    @Test(arguments: [
        // The library records the URL without one trailing slash,
        // and names the directory without any.
        ("lore://slash.invalid:43000/", "lore://slash.invalid:43000", "slash.invalid_43000"),
        ("lore://slashes.invalid:43000//", "lore://slashes.invalid:43000/", "slashes.invalid_43000"),
        // It replaces each `/` of a path with `_`.
        ("lore://path.invalid:43000/a/b", "lore://path.invalid:43000/a/b", "path.invalid_43000_a_b"),
    ])
    func createRecordsTheServerURL(url: String, recorded: String, directoryName: String) async throws {
        let directory = temporaryPath("shared-stores")
        let store = try await SharedStore.create(for: url, in: directory, options: offline)
        #expect(store.remote == recorded)
        #expect(store.path == "\(directory)/\(directoryName)/shared_store")
        #expect(try await SharedStore.all().filter { $0.path.hasPrefix(directory) } == [store])
    }

    @Test func pathsOfTheSameStoreCompareEqual() async {
        await #expect(processExitsWith: .success) {
            _ = isolateGlobalDirectory()
            let offline = Repository.Options(identity: "test@example.com", isOffline: true)
            // A directory under `/private/tmp` that doesn't exist yet,
            // where the file system's standardization of the path
            // changes once the directory exists.
            let base = "/private/tmp/lore-swift-tests-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: base) }
            let store = try await SharedStore.create(
                for: "lore://shared-store.invalid:43000",
                in: "\(base)/stores",
                makingDefault: true,
                options: offline
            )
            #expect(store.path == "\(base)/stores/shared-store.invalid_43000/shared_store")
            #expect(try await SharedStore.all().filter { $0.remote == store.remote } == [store])
            #expect(try await SharedStore.configuration().defaultStores.map(\.path) == [store.path])

            let other = try await SharedStore.create(for: "lore://other.invalid:43000", options: offline)
            #expect(try await SharedStore.all().filter { $0.remote == other.remote } == [other])
        }
    }

    @Test func createConnectsToTheServerUnlessOffline() async throws {
        let directory = temporaryPath("shared-stores")
        // Nothing listens on the discard port.
        let error = await #expect(throws: LoreError.self) {
            try await SharedStore.create(for: "lore://127.0.0.1:9", in: directory)
        }
        #expect(error?.code == .disconnected)
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    @Test func offlineRepositoriesShareAStore() async throws {
        let directory = temporaryPath("shared-stores")
        let first = try await Repository.create(
            at: temporaryRepositoryPath("first"),
            name: "shared",
            store: .shared(in: directory),
            options: offline
        )
        let second = try await Repository.create(
            at: temporaryRepositoryPath("second"),
            name: "shared",
            store: .shared(in: directory),
            options: offline
        )
        // A repository without a server keeps the store directly in the directory.
        #expect(FileManager.default.fileExists(atPath: "\(directory)/shared_store/shared_store.toml"))
        #expect(!FileManager.default.fileExists(atPath: "\(first.path)/.lore/immutable"))

        try first.write("hello\n", to: "a.txt")
        try await first.stage(["a.txt"])
        try await first.commit(message: "First")
        #expect(try await first.storedContent(of: "a.txt") != nil)

        let store = try #require(
            try await SharedStore.all(includingInstances: true).first { $0.path.hasPrefix(directory) }
        )
        #expect(store.remote == "")
        #expect(store.path == "\(directory)/shared_store")
        let firstInstance = try #require(try await first.instances().first)
        let secondInstance = try #require(try await second.instances().first)
        #expect(
            Set(store.instances) == [
                SharedStore.Instance(id: firstInstance.id, path: first.absolutePath),
                SharedStore.Instance(id: secondInstance.id, path: second.absolutePath),
            ]
        )
    }

    @Test func sharedStoreInARelativeDirectory() async throws {
        let directory = temporaryPath("shared-stores")
        let relative = relativePath(to: directory)
        let repository = try await Repository.create(
            at: temporaryRepositoryPath(),
            name: "shared",
            store: .shared(in: relative),
            options: offline
        )
        // The directory is relative to the current directory, not to the new checkout.
        #expect(FileManager.default.fileExists(atPath: "\(directory)/shared_store/shared_store.toml"))
        #expect(!FileManager.default.fileExists(atPath: "\(repository.path)/\(relative)"))
        #expect(!FileManager.default.fileExists(atPath: "\(repository.path)/.lore/immutable"))
    }

    @Test func storeLocationsAndTheGlobalConfiguration() async {
        await #expect(processExitsWith: .success) {
            let global = isolateGlobalDirectory()
            let offline = Repository.Options(identity: "test@example.com", isOffline: true)
            let defaultDirectory = "\(global)/data/shared_store"
            #expect(
                try await SharedStore.configuration()
                    == SharedStore.Configuration(isUsedAutomatically: false, defaultStores: [])
            )

            let store = try await SharedStore.create(
                for: "lore://shared-store.invalid:43000",
                in: "\(global)/stores",
                makingDefault: true,
                options: offline
            )
            // A store in the default directory isn't a default unless you make it one.
            let other = try await SharedStore.create(for: "lore://other.invalid:43000", options: offline)
            #expect(other.path == "\(defaultDirectory)/other.invalid_43000/shared_store")
            #expect(try await SharedStore.all().contains(other))
            let defaults = [
                SharedStore.Configuration.DefaultStore(
                    serverAddress: "shared-store.invalid:43000",
                    path: store.path,
                    exists: true
                )
            ]
            #expect(try await SharedStore.configuration().defaultStores == defaults)

            // A checkout that asks for the default store of a server
            // makes the store and records it as the default.
            // An offline repository has no server, so its server is the empty string.
            let shared = try await Repository.create(
                at: temporaryRepositoryPath(),
                name: "shared",
                store: .shared(),
                options: offline
            )
            #expect(!FileManager.default.fileExists(atPath: "\(shared.path)/.lore/immutable"))
            #expect(FileManager.default.fileExists(atPath: "\(defaultDirectory)/shared_store/shared_store.toml"))
            #expect(
                Set(try await SharedStore.configuration().defaultStores)
                    == Set(
                        defaults + [
                            SharedStore.Configuration.DefaultStore(
                                serverAddress: "",
                                path: "\(defaultDirectory)/shared_store",
                                exists: true
                            )
                        ]
                    )
            )

            try await SharedStore.setUsedAutomatically(true)
            #expect(try await SharedStore.configuration().isUsedAutomatically)
            let text = try String(contentsOfFile: "\(global)/config/config.toml", encoding: .utf8)
            #expect(text.contains("use_shared_store_automatically = true"))
            // A new repository now uses the default shared store,
            // unless it asks for a local store.
            let automatic = try await makeOfflineRepository()
            #expect(!FileManager.default.fileExists(atPath: "\(automatic.path)/.lore/immutable"))
            let local = try await Repository.create(
                at: temporaryRepositoryPath(),
                name: "local",
                store: .local,
                options: offline
            )
            #expect(FileManager.default.fileExists(atPath: "\(local.path)/.lore/immutable"))

            try await SharedStore.setUsedAutomatically(false)
            #expect(try await SharedStore.configuration().isUsedAutomatically == false)
            let unshared = try await makeOfflineRepository()
            #expect(FileManager.default.fileExists(atPath: "\(unshared.path)/.lore/immutable"))
        }
    }
}
