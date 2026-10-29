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
    let remoteURL = "lore://shared-store.invalid:43000"
    let offline = Repository.Options(identity: "test@example.com", isOffline: true)

    @Test func createRecordsTheStoreInTheRegistry() async throws {
        let directory = temporaryPath("shared-stores")
        let path = try await SharedStore.create(for: remoteURL, in: directory, options: offline)
        let serverDirectory = "\(directory)/shared-store.invalid_43000"
        #expect(path == "\(serverDirectory)/shared_store")
        #expect(FileManager.default.fileExists(atPath: "\(path)/shared_store.toml"))

        let stores = try await SharedStore.all().filter { $0.path.hasPrefix(directory) }
        #expect(stores == [SharedStore(remoteURL: remoteURL, path: serverDirectory, instances: [])])
        let withInstances = try await SharedStore.all(includingInstances: true).filter { $0.path.hasPrefix(directory) }
        #expect(withInstances == stores)

        let again = await #expect(throws: LoreError.self) {
            try await SharedStore.create(for: remoteURL, in: directory, options: offline)
        }
        #expect(again?.message.contains("Found existing shared store") == true)
        let empty = await #expect(throws: LoreError.self) {
            try await SharedStore.create(for: "", in: directory, options: offline)
        }
        #expect(empty?.code == .invalidArguments)
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
        #expect(store.remoteURL == "")
        let firstInstance = try #require(try await first.instances().first)
        let secondInstance = try #require(try await second.instances().first)
        #expect(
            Set(store.instances) == [
                SharedStore.Instance(id: firstInstance.id, path: first.absolutePath),
                SharedStore.Instance(id: secondInstance.id, path: second.absolutePath),
            ]
        )
    }

    @Test func localStoreLocation() async throws {
        let repository = try await Repository.create(
            at: temporaryRepositoryPath(),
            name: "local",
            store: .local,
            options: offline
        )
        #expect(FileManager.default.fileExists(atPath: "\(repository.path)/.lore/immutable"))
    }

    @Test func configurationRecordsDefaultsAndAutomaticUse() async {
        await #expect(processExitsWith: .success) {
            let global = isolateGlobalDirectory()
            let offline = Repository.Options(identity: "test@example.com", isOffline: true)
            #expect(
                try await SharedStore.configuration()
                    == SharedStore.Configuration(isUsedAutomatically: false, defaultStores: [])
            )

            let path = try await SharedStore.create(
                for: "lore://shared-store.invalid:43000",
                in: "\(global)/stores",
                makingDefault: true,
                options: offline
            )
            // A store in the default directory isn't a default unless you make it one.
            let other = try await SharedStore.create(for: "lore://other.invalid:43000", options: offline)
            #expect(other == "\(global)/data/shared_store/other.invalid_43000/shared_store")
            #expect(
                try await SharedStore.configuration().defaultStores == [
                    SharedStore.Configuration.DefaultStore(
                        remoteURL: "shared-store.invalid:43000",
                        path: path,
                        exists: true
                    )
                ]
            )

            try await SharedStore.setUsedAutomatically(true)
            #expect(try await SharedStore.configuration().isUsedAutomatically)
            let text = try String(contentsOfFile: "\(global)/config/config.toml", encoding: .utf8)
            #expect(text.contains("use_shared_store_automatically = true"))
            // A new repository now uses a shared store in the default directory.
            let repository = try await makeOfflineRepository()
            #expect(!FileManager.default.fileExists(atPath: "\(repository.path)/.lore/immutable"))
            #expect(FileManager.default.fileExists(atPath: "\(global)/data/shared_store/shared_store"))

            try await SharedStore.setUsedAutomatically(false)
            #expect(try await SharedStore.configuration().isUsedAutomatically == false)
            let local = try await makeOfflineRepository()
            #expect(FileManager.default.fileExists(atPath: "\(local.path)/.lore/immutable"))
        }
    }
}
