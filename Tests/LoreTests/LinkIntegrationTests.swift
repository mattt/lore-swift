import Foundation
import Testing

@testable import Lore

/// Tests of links and layers against a local server.
///
/// Run them with `Scripts/run-integration-tests.sh`,
/// which starts a server and sets `LORE_INTEGRATION=1`.
@Suite(.integration) struct LinkIntegrationTests {
    /// Creates a repository on the server with one pushed revision of the given files.
    private func makePublishedRepository(
        _ label: String,
        files: [String: String]
    ) async throws -> (repository: Repository, url: String) {
        let path = temporaryRepositoryPath(label)
        let url = "\(serverURL)/\(URL(filePath: path).lastPathComponent)"
        let repository = try await Repository.create(
            at: path,
            name: url,
            options: Repository.Options(identity: "alice@example.com")
        )
        for (file, text) in files {
            try FileManager.default.createDirectory(
                atPath: URL(filePath: "\(path)/\(file)").deletingLastPathComponent().path,
                withIntermediateDirectories: true
            )
            try repository.write(text, to: file)
        }
        try await repository.stage(["."])
        try await repository.commit(message: "First")
        try await repository.push()
        return (repository, url)
    }

    /// Returns a published library, a published app, and the library's URL.
    private func makeLibraryAndApp() async throws -> (library: Repository, app: Repository, url: String) {
        let (library, url) = try await makePublishedRepository(
            "library",
            files: ["x.txt": "x1\n", "sub/y.txt": "y1\n"]
        )
        let (app, _) = try await makePublishedRepository("app", files: ["a.txt": "a\n"])
        return (library, app, url)
    }

    /// Commits a change to `x.txt` in a repository and pushes it.
    private func commitAndPush(_ text: String, in repository: Repository) async throws -> Revision {
        try repository.write(text, to: "x.txt")
        try await repository.stage(["x.txt"])
        let revision = try await repository.commit(message: "Change x.txt")
        try await repository.push()
        return revision
    }

    @Test func linkedFilesAppearAtTheLinkPath() async throws {
        let (library, app, url) = try await makeLibraryAndApp()
        let libraryID = try await library.info().id
        let latest = try await library.revision()

        let pin = try await app.addLink(to: url, at: "vendor/library")
        #expect(pin == latest.id)
        #expect(try app.read("vendor/library/x.txt") == "x1\n")
        #expect(try app.read("vendor/library/sub/y.txt") == "y1\n")

        let links = try await app.links()
        #expect(links.map(\.path) == ["vendor/library"])
        let link = try #require(links.first)
        #expect(link.repositoryID == libraryID)
        #expect(link.sourcePath == "/")
        #expect(link.revision == latest.id)
        #expect(link.branchID == (try await app.status().branchID))
        #expect(link.tracksCurrentBranch)
        #expect(link.createsBranches)

        // The link is staged until the next commit.
        let staged = try await app.linkInfo(at: "vendor/library")
        #expect(staged.link == link)
        #expect(staged.stagedChange == .added)
        #expect(staged.stagedFileCount == 0)
        #expect(staged.remoteRevision == latest.id)
        let status = try await app.status()
        #expect(status.files.filter(\.isStaged).map(\.path) == ["vendor", "vendor/library"])
        let update = await #expect(throws: LoreError.self) {
            try await app.updateLink(at: "vendor/library")
        }
        #expect(update?.code == .internal)

        try await app.commit(message: "Link the library")
        #expect(try await app.linkInfo(at: "vendor/library").stagedChange == nil)
        let push = try await app.push()
        #expect(push.revisionCount == 1)

        let clone = try await Repository.clone(
            from: "\(serverURL)/\(URL(filePath: app.path).lastPathComponent)",
            to: temporaryRepositoryPath("clone"),
            options: Repository.Options(identity: "bob@example.com")
        )
        #expect(try clone.read("vendor/library/x.txt") == "x1\n")
        #expect(try await clone.links() == links)
    }

    @Test func updateMovesALinkToANewerRevision() async throws {
        let (library, app, url) = try await makeLibraryAndApp()
        let first = try await library.revision()
        try await app.addLink(to: url, at: "vendor/library")
        try await app.commit(message: "Link the library")
        #expect(try await app.updateLink(at: "vendor/library") == nil)

        let second = try await commitAndPush("x2\n", in: library)
        #expect(try await app.linkInfo(at: "vendor/library").remoteRevision == second.id)
        #expect(try await app.updateLink(at: "vendor/library") == second.id)
        #expect(try app.read("vendor/library/x.txt") == "x2\n")
        let updated = try await app.linkInfo(at: "vendor/library")
        #expect(updated.link.revision == second.id)
        #expect(updated.stagedChange == .modified)
        // An update names the link's branch.
        #expect(!updated.link.tracksCurrentBranch)
        try await app.commit(message: "Update the library")

        #expect(try await app.updateLink(at: "vendor/library", to: .number(1, on: "main")) == first.id)
        #expect(try app.read("vendor/library/x.txt") == "x1\n")
        try await app.commit(message: "Pin the library")
        #expect(try await app.links().first?.revision == first.id)

        let error = await #expect(throws: LoreError.self) {
            try await app.updateLink(at: "vendor/library", to: "main")
        }
        #expect(error?.code == .revisionNotFound)
    }

    @Test func committingInsideALinkCommitsTheLinkedRepository() async throws {
        let (library, app, url) = try await makeLibraryAndApp()
        let libraryID = try await library.info().id
        try await app.addLink(to: url, at: "vendor/library")
        try await app.commit(message: "Link the library")

        try app.write("x from app\n", to: "vendor/library/x.txt")
        try app.write("a2\n", to: "a.txt")
        try await app.stage(["."])
        #expect(
            try await app.stagedLinks()
                == [StagedLink(path: "vendor/library", repositoryID: libraryID, stagedFileCount: 1)]
        )
        let info = try await app.linkInfo(at: "vendor/library")
        #expect(info.stagedChange == .modified)
        #expect(info.stagedFileCount == 1)

        let revision = try await app.commit(
            message: "Change the app and the library",
            linkMessages: ["vendor/library": "Change the library from the app"]
        )
        #expect(revision.message == "Change the app and the library")
        #expect(try await app.status().revision == revision.id)
        #expect(try await app.stagedLinks().isEmpty)
        try await app.push()

        try await library.sync()
        #expect(try library.read("x.txt") == "x from app\n")
        let history = try await library.history(limit: 1)
        #expect(history.first?.message == "Change the library from the app")
        #expect(try await app.links().first?.revision == history.first?.id)

        // Without a message for the link, the linked revision gets the commit message.
        try app.write("x again\n", to: "vendor/library/x.txt")
        try await app.stage(["vendor/library/x.txt"])
        try await app.commit(message: "Change the library again")
        try await app.push()
        try await library.sync()
        #expect(try await library.history(limit: 1).first?.message == "Change the library again")
    }

    @Test func removingALink() async throws {
        let (_, app, url) = try await makeLibraryAndApp()
        try await app.addLink(to: url, at: "vendor/library")
        try await app.commit(message: "Link the library")

        try await app.removeLink(at: "vendor/library")
        #expect(!FileManager.default.fileExists(atPath: "\(app.path)/vendor/library/x.txt"))
        #expect(try await app.links().isEmpty)
        #expect(try await app.linkInfo(at: "vendor/library").stagedChange == .removed)
        #expect(try await app.status().files.map(\.action) == [.delete])
        try await app.commit(message: "Remove the library")
        try await app.push()

        let clone = try await Repository.clone(
            from: "\(serverURL)/\(URL(filePath: app.path).lastPathComponent)",
            to: temporaryRepositoryPath("clone"),
            options: Repository.Options(identity: "bob@example.com")
        )
        #expect(!FileManager.default.fileExists(atPath: "\(clone.path)/vendor/library"))
        #expect(try await clone.links().isEmpty)
    }

    @Test func removingAStagedLinkUnstagesIt() async throws {
        let (_, app, url) = try await makeLibraryAndApp()
        try await app.addLink(to: url, at: "vendor/library")
        try await app.removeLink(at: "vendor/library")
        #expect(!FileManager.default.fileExists(atPath: "\(app.path)/vendor/library/x.txt"))
        #expect(try await app.links().isEmpty)
    }

    @Test func linkASubdirectoryPinnedToARevision() async throws {
        let (library, app, url) = try await makeLibraryAndApp()
        let first = try await library.revision()
        try await commitAndPush("x2\n", in: library)
        let name = try #require(URL(string: url)?.lastPathComponent)

        let pin = try await app.addLink(
            to: name,
            at: "vendor/sub",
            sourcePath: "sub",
            pinnedTo: .id(first.id),
            creatingBranches: false
        )
        #expect(pin == first.id)
        #expect(try app.read("vendor/sub/y.txt") == "y1\n")
        #expect(!FileManager.default.fileExists(atPath: "\(app.path)/vendor/sub/x.txt"))

        let link = try #require(try await app.links().first)
        #expect(link.sourcePath == "sub")
        #expect(link.revision == first.id)
        #expect(!link.createsBranches)
        #expect(!link.tracksCurrentBranch)

        let branch = try await app.branchInfo(named: "main", inLinkAt: "vendor/sub")
        #expect(branch.id == link.branchID)
        #expect(branch.latestRevision != first.id)

        let overlap = await #expect(throws: LoreError.self) {
            try await app.addLink(to: url, at: "vendor/library")
        }
        #expect(overlap?.code == .invalidArguments)
        let missing = await #expect(throws: LoreError.self) {
            try await app.addLink(to: "\(serverURL)/no-such-repository", at: "vendor/none")
        }
        #expect(missing?.code == .notFound)
    }

    @Test func mergingABranchMergesItsLinks() async throws {
        let (library, app, url) = try await makeLibraryAndApp()
        try await app.addLink(to: url, at: "vendor/library")
        try await app.commit(message: "Link the library")
        try await app.push()

        // Creating a branch creates the matching branch in the linked repository.
        try await app.createBranch(named: "feature")
        try await app.switchBranch(to: "feature")
        #expect(try await library.branches().contains { $0.name == "feature" && $0.location == .remote })
        try app.write("x feature\n", to: "vendor/library/x.txt")
        try app.write("a feature\n", to: "a.txt")
        try await app.stage(["."])
        let feature = try await app.commit(message: "Feature")
        try await app.push()

        try await app.switchBranch(to: "main")
        #expect(try app.read("vendor/library/x.txt") == "x1\n")
        let result = try await app.mergeBranch(
            named: "feature",
            message: "Merge feature",
            linkMessages: ["vendor/library": "Merge feature into the library"]
        )
        #expect(result.sourceRevision == feature.id)
        #expect(result.conflicts.isEmpty)
        #expect(result.revision?.message == "Merge feature")
        #expect(try app.read("a.txt") == "a feature\n")
        #expect(try app.read("vendor/library/x.txt") == "x feature\n")
        try await app.push()
        try await library.sync()
        #expect(try library.read("x.txt") == "x feature\n")
        #expect(try await library.history(limit: 1).first?.message == "Merge feature into the library")

        try await app.archiveBranch(named: "feature", includingLinks: true)
        #expect(try await library.branches().allSatisfy { $0.name != "feature" })
    }

    @Test func mergingABranchWithoutItsLinks() async throws {
        let (_, app, url) = try await makeLibraryAndApp()
        try await app.addLink(to: url, at: "vendor/library")
        try await app.commit(message: "Link the library")
        try await app.push()
        let pin = try await app.links().first?.revision

        try await app.createBranch(named: "feature")
        try await app.switchBranch(to: "feature")
        try app.write("x feature\n", to: "vendor/library/x.txt")
        try app.write("a feature\n", to: "a.txt")
        try await app.stage(["."])
        try await app.commit(message: "Feature")
        try await app.push()

        try await app.switchBranch(to: "main")
        try await app.mergeBranch(named: "feature", message: "Merge feature", includingLinks: false)
        #expect(try app.read("a.txt") == "a feature\n")
        #expect(try app.read("vendor/library/x.txt") == "x1\n")
        #expect(try await app.links().first?.revision == pin)

        // Lore 0.11.0 can't archive a branch in links that you never switched to.
        try await app.createBranch(named: "unused")
        let error = await #expect(throws: LoreError.self) {
            try await app.archiveBranch(named: "unused", includingLinks: true)
        }
        #expect(error?.code == .branchNotFound)
    }

    @Test func layerFilesStayOnThisMachine() async throws {
        let (library, app, url) = try await makeLibraryAndApp()
        let libraryID = try await library.info().id
        let latest = try await library.revision()
        let name = try #require(URL(string: url)?.lastPathComponent)

        let layer = try await app.addLayer(from: name, at: "overlay")
        #expect(layer.path == "overlay")
        #expect(layer.repositoryID == libraryID)
        #expect(layer.sourcePath == "")
        #expect(layer.metadataKey == nil)
        #expect(layer.revision == latest.id)
        #expect(try await app.layers() == [layer])
        #expect(try app.read("overlay/x.txt") == "x1\n")
        #expect(try app.read("overlay/sub/y.txt") == "y1\n")
        // The layer isn't part of this repository.
        #expect(try await app.status().files.isEmpty)

        let again = await #expect(throws: LoreError.self) {
            try await app.addLayer(from: name, at: "overlay")
        }
        #expect(again?.code == .alreadyLinked)
        let byURL = await #expect(throws: LoreError.self) {
            try await app.addLayer(from: url, at: "other")
        }
        #expect(byURL?.code == .notFound)

        let sub = try await app.addLayer(from: libraryID.description, at: "overlay-sub", sourcePath: "sub")
        #expect(sub.sourcePath == "sub")
        #expect(try app.read("overlay-sub/y.txt") == "y1\n")
        #expect(try await app.layers().map(\.path) == ["overlay", "overlay-sub"])

        try app.write("a2\n", to: "a.txt")
        try await app.stage(["a.txt"])
        try await app.commit(message: "Change the app")
        try await app.push()
        let clone = try await Repository.clone(
            from: "\(serverURL)/\(URL(filePath: app.path).lastPathComponent)",
            to: temporaryRepositoryPath("clone"),
            options: Repository.Options(identity: "bob@example.com")
        )
        #expect(try clone.read("a.txt") == "a2\n")
        #expect(!FileManager.default.fileExists(atPath: "\(clone.path)/overlay"))
        #expect(try await clone.layers().isEmpty)
    }

    @Test func committingInALayerCommitsItsRepository() async throws {
        let (library, app, url) = try await makeLibraryAndApp()
        let name = try #require(URL(string: url)?.lastPathComponent)
        try await app.addLayer(from: name, at: "overlay")
        let appRevision = try await app.revision()

        try app.write("x from the layer\n", to: "overlay/x.txt")
        try await app.stage(["overlay/x.txt"])
        let revision = try await app.commit(message: "Change the layer")
        try await app.push()
        // With only files of a layer staged, this repository gets no revision.
        #expect(try await app.revision().id == appRevision.id)

        try await library.sync()
        #expect(try library.read("x.txt") == "x from the layer\n")
        let history = try await library.history(limit: 1)
        #expect(history.first?.message == "Change the layer")
        #expect(revision.id == history.first?.id)
        #expect(revision.metadata.isEmpty)
        #expect(try await app.layers().first?.revision == revision.id)
    }

    @Test func aLayerMatchesRevisionsByMetadata() async throws {
        let (library, app, url) = try await makeLibraryAndApp()
        let name = try #require(URL(string: url)?.lastPathComponent)
        try await library.setRevisionMetadata(["build": .string("7")])
        let matching = try await commitAndPush("x for build 7\n", in: library)
        try await library.setRevisionMetadata(["build": .string("8")])
        try await commitAndPush("x for build 8\n", in: library)
        try await app.setRevisionMetadata(["build": .string("7")])
        try app.write("a for build 7\n", to: "a.txt")
        try await app.stage(["a.txt"])
        try await app.commit(message: "Build 7")

        let layer = try await app.addLayer(from: name, at: "overlay", matchingMetadataKey: "build")
        #expect(layer.metadataKey == "build")
        #expect(layer.revision == matching.id)
        #expect(try app.read("overlay/x.txt") == "x for build 7\n")
    }

    @Test func archivingABranchInLayers() async throws {
        let (library, app, url) = try await makeLibraryAndApp()
        let name = try #require(URL(string: url)?.lastPathComponent)
        try await app.addLayer(from: name, at: "overlay")
        try await app.createBranch(named: "feature")
        try await app.switchBranch(to: "feature")
        try app.write("x on feature\n", to: "overlay/x.txt")
        try await app.stage(["overlay/x.txt"])
        try await app.commit(message: "Change the layer on feature")
        // After the commit and the push,
        // the layer's repository has the branch on the server.
        try await app.push()
        #expect(try await library.branches().contains { $0.name == "feature" })
        try await app.switchBranch(to: "main")

        try await app.archiveBranch(named: "feature", includingLayers: true)
        #expect(try await library.branches().allSatisfy { $0.name != "feature" })
    }

    @Test func removingALayer() async throws {
        let (_, app, url) = try await makeLibraryAndApp()
        let name = try #require(URL(string: url)?.lastPathComponent)
        try await app.addLayer(from: name, at: "overlay")
        try await app.addLayer(from: name, at: "overlay-sub", sourcePath: "sub")

        try app.write("changed\n", to: "overlay/x.txt")
        let modified = await #expect(throws: LoreError.self) {
            try await app.removeLayer(at: "overlay")
        }
        #expect(modified?.code == .localModifications)
        #expect(try app.read("overlay/x.txt") == "changed\n")
        try await app.removeLayer(at: "overlay", discardingLocalChanges: true)
        #expect(!FileManager.default.fileExists(atPath: "\(app.path)/overlay"))

        try app.write("untracked\n", to: "overlay-sub/untracked.txt")
        try await app.removeLayer(at: "overlay-sub", from: name)
        #expect(!FileManager.default.fileExists(atPath: "\(app.path)/overlay-sub/y.txt"))
        #expect(try app.read("overlay-sub/untracked.txt") == "untracked\n")
        #expect(try await app.layers().isEmpty)

        try await app.addLayer(from: name, at: "overlay-sub", sourcePath: "sub")
        try await app.removeLayer(at: "overlay-sub", deletingUntrackedFiles: true)
        #expect(!FileManager.default.fileExists(atPath: "\(app.path)/overlay-sub"))

        let missing = await #expect(throws: LoreError.self) {
            try await app.removeLayer(at: "overlay")
        }
        #expect(missing?.code == .layerNotFound)
    }
}
