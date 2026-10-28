import Foundation
import Testing

@testable import Lore

@Suite struct LinkTests {
    @Test func anOfflineRepositoryHasNoLinksOrLayers() async throws {
        let repository = try await makeOfflineRepository()
        #expect(try await repository.links().isEmpty)
        #expect(try await repository.stagedLinks().isEmpty)
        #expect(try await repository.layers().isEmpty)
    }

    @Test func linksAndLayersNeedAServer() async throws {
        let repository = try await makeOfflineRepository()
        let link = await #expect(throws: LoreError.self) {
            try await repository.addLink(to: "library", at: "vendor/library")
        }
        #expect(link?.code == .noRemote)
        let layer = await #expect(throws: LoreError.self) {
            try await repository.addLayer(from: "library", at: "overlay")
        }
        #expect(layer?.code == .noRemote)
        #expect(!FileManager.default.fileExists(atPath: "\(repository.path)/vendor/library"))
    }

    @Test func pathsThatArentLinks() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("a\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.commit(message: "First")

        let missing = await #expect(throws: LoreError.self) {
            try await repository.linkInfo(at: "vendor")
        }
        #expect(missing?.code == .nodeNotFound)
        let file = await #expect(throws: LoreError.self) {
            try await repository.linkInfo(at: "a.txt")
        }
        #expect(file?.code == .notALink)
        let update = await #expect(throws: LoreError.self) {
            try await repository.updateLink(at: "a.txt")
        }
        #expect(update?.code == .notALink)
        let removal = await #expect(throws: LoreError.self) {
            try await repository.removeLink(at: "vendor")
        }
        #expect(removal?.code == .nodeNotFound)
    }

    @Test func aCommitMessageForAPathThatIsntALink() async throws {
        let repository = try await makeOfflineRepository()
        try repository.write("a\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        let error = await #expect(throws: LoreError.self) {
            try await repository.commit(message: "First", linkMessages: ["a.txt": "Linked"])
        }
        #expect(error?.code == .invalidArguments)
    }

    @Test func removingALayerThatDoesntExist() async throws {
        let repository = try await makeOfflineRepository()
        let error = await #expect(throws: LoreError.self) {
            try await repository.removeLayer(at: "overlay")
        }
        #expect(error?.code == .layerNotFound)
    }
}
