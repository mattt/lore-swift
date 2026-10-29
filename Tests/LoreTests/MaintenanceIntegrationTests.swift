import Foundation
import Testing

@testable import Lore

/// Tests of repository administration, maintenance, and shared stores
/// against the local server that accepts every request.
///
/// Run them with `Scripts/run-integration-tests.sh`.
/// Every repository and store is one that a test creates in the scratch directory.
@Suite(.integration) struct MaintenanceIntegrationTests {
    /// Creates a repository on the server with one pushed revision.
    private func makePublishedRepository(
        _ label: String = "published",
        store: Repository.StoreLocation = .automatic
    ) async throws -> (repository: Repository, url: String) {
        let path = temporaryRepositoryPath(label)
        let url = "\(serverURL)/\(URL(filePath: path).lastPathComponent)"
        let repository = try await Repository.create(
            at: path,
            name: url,
            store: store,
            options: Repository.Options(identity: "alice@example.com")
        )
        try repository.write("hello\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "First")
        try await repository.push()
        return (repository, url)
    }

    @Test func serverListsItsRepositories() async throws {
        let (repository, _) = try await makePublishedRepository()
        let info = try await repository.info()
        let repositories = try await Repository.repositories(on: serverURL)
        #expect(repositories.contains(RemoteRepository(id: info.id, name: info.name)))
        #expect(try await repository.configurationValue(forKey: .remoteURL) == serverURL)
    }

    @Test func openServerRefusesToDeleteRepositories() async throws {
        // The open server identifies every user as `<unknown>`,
        // who isn't the creator of any repository.
        let (repository, url) = try await makePublishedRepository()
        let error = await #expect(throws: LoreError.self) {
            try await repository.deleteFromServer()
        }
        #expect(error?.code == .notAuthorized)
        let byURL = await #expect(throws: LoreError.self) {
            try await Repository.deleteFromServer(url, options: repository.options)
        }
        #expect(byURL?.code == .notAuthorized)
        #expect(
            try await Repository.repositories(on: serverURL).contains {
                $0.name == (URL(string: url)?.lastPathComponent ?? "")
            }
        )
    }

    @Test func storeEntriesIncludeTheServer() async throws {
        let (repository, _) = try await makePublishedRepository()
        let stored = try #require(try await repository.storedContent(of: "a.txt"))

        let entries = try await repository.storeEntries(for: stored.address)
        #expect(entries.map(\.isOnServer) == [false, true])
        #expect(entries.allSatisfy { $0.address == stored.address && $0.match == .address })
        #expect(entries.last?.hasPayload == true)
        #expect(entries.last?.contentSize == stored.size)

        let local = try await repository.storeEntries(for: stored.address, checkingServer: false)
        #expect(local == Array(entries.prefix(1)))
    }

    @Test func instancesInASharedStore() async throws {
        let directory = temporaryPath("shared-stores")
        // The library names the directory for a server after its URL without the scheme.
        let serverDirectory =
            "\(directory)/"
            + String(serverURL.split(separator: "://").last ?? "")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let path = try await SharedStore.create(for: serverURL, in: directory)
        #expect(path == "\(serverDirectory)/shared_store")

        let (repository, url) = try await makePublishedRepository("shared", store: .shared(in: directory))
        let removed = try await Repository.clone(
            from: url,
            to: temporaryRepositoryPath("removed"),
            store: .shared(in: directory),
            options: Repository.Options(identity: "bob@example.com")
        )
        let emptied = try await Repository.clone(
            from: url,
            to: temporaryRepositoryPath("emptied"),
            store: .shared(in: directory),
            options: Repository.Options(identity: "bob@example.com")
        )
        let instances = try await repository.instances()
        #expect(Set(instances.map(\.path)) == [repository.absolutePath, removed.absolutePath, emptied.absolutePath])
        #expect(instances.allSatisfy { $0.staleness == nil && $0.branch == "main" })
        #expect(Set(try await removed.instances()) == Set(instances))

        let store = try #require(
            try await SharedStore.all(includingInstances: true).first { $0.path.hasPrefix(directory) }
        )
        #expect(store.remoteURL == serverURL)
        #expect(store.path == serverDirectory)
        #expect(Set(store.instances.map(\.id)) == Set(instances.map(\.id)))

        try FileManager.default.removeItem(atPath: removed.path)
        try FileManager.default.removeItem(atPath: "\(emptied.path)/.lore")
        let stale = try await repository.instances().filter { $0.staleness != nil }
        #expect(
            Set(stale.map { [$0.path: $0.staleness] }) == [
                [removed.absolutePath: .pathMissing], [emptied.absolutePath: .noCheckout],
            ]
        )

        let pruned = try await repository.pruneStaleInstances()
        #expect(Set(pruned) == Set(stale))
        #expect(try await repository.instances().map(\.path) == [repository.absolutePath])
        #expect(try await repository.pruneStaleInstances().isEmpty)
    }
}
