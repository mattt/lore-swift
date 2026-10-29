import Testing

@testable import Lore

@Suite struct MetadataTests {
    /// Returns an offline repository with a committed file `a.txt`
    /// whose next change is staged.
    private func repositoryWithStagedFile() async throws -> Repository {
        let repository = try await makeOfflineRepository()
        try repository.write("hello\n", to: "a.txt")
        try repository.write("world\n", to: "b.txt")
        try await repository.stage(["."])
        try await repository.commit(message: "First")
        try repository.write("hello again\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        return repository
    }

    @Test func setAndGetTypedValues() async throws {
        let repository = try await repositoryWithStagedFile()
        let hash = Array(repeating: UInt8(0xab), count: 32)
        let values: [String: MetadataValue] = [
            "kind": .string("texture"),
            "size": .number(42),
            "approved": .boolean(true),
            "source": .hash(hash),
        ]
        try await repository.setMetadata(values, of: ["a.txt"])
        for (key, value) in values {
            #expect(try await repository.metadata(forKey: key, of: "a.txt") == value)
        }
        #expect(try await repository.metadata(forKey: "missing", of: "a.txt") == nil)
    }

    @Test func metadataIsPartOfTheCommit() async throws {
        let repository = try await repositoryWithStagedFile()
        try await repository.setMetadata(["kind": .string("texture")], of: ["a.txt"])
        let revision = try await repository.commit(message: "Second")

        #expect(try await repository.metadata(forKey: "kind", of: "a.txt", revision: "main@2") == .string("texture"))
        #expect(
            try await repository.metadata(forKey: "kind", of: "a.txt", revision: .id(revision.id)) == .string("texture")
        )
        #expect(try await repository.metadata(forKey: "kind", of: "a.txt", revision: .number(1)) == nil)
    }

    @Test func setsValuesOnSeveralFiles() async throws {
        let repository = try await repositoryWithStagedFile()
        try repository.write("world, again\n", to: "b.txt")
        try await repository.stage(["b.txt"])
        try await repository.setMetadata(["kind": .string("text"), "lines": .number(1)], of: ["a.txt", "b.txt"])
        for path in ["a.txt", "b.txt"] {
            #expect(try await repository.metadata(forKey: "kind", of: path) == .string("text"))
            #expect(try await repository.metadata(forKey: "lines", of: path) == .number(1))
        }
    }

    @Test func listAndClearMetadata() async throws {
        let repository = try await repositoryWithStagedFile()
        let values: [String: MetadataValue] = ["kind": .string("texture"), "size": .number(42)]
        try await repository.setMetadata(values, of: ["a.txt"])
        #expect(try await repository.metadata(of: "a.txt") == values)
        #expect(try await repository.metadata(of: "b.txt").isEmpty)
        try await repository.commit(message: "Second")
        #expect(try await repository.metadata(of: "a.txt", revision: "main@2") == values)
        #expect(try await repository.metadata(of: "a.txt", revision: "main@1").isEmpty)

        try repository.write("hello, once more\n", to: "a.txt")
        try await repository.stage(["a.txt"])
        try await repository.clearMetadata(of: "a.txt")
        #expect(try await repository.metadata(of: "a.txt").isEmpty)
        try await repository.commit(message: "Third")
        #expect(try await repository.metadata(of: "a.txt", revision: "main@3").isEmpty)
        #expect(try await repository.metadata(of: "a.txt", revision: "main@2") == values)
    }

    @Test(arguments: [MetadataValue.binary([0xff, 0xfe]), .address(ContentAddress(hash: Array(repeating: 1, count: 32), context: Array(repeating: 2, count: 16))!)])
    func refusesValuesTheBindingCannotSet(value: MetadataValue) async throws {
        let repository = try await repositoryWithStagedFile()
        let error = await #expect(throws: LoreError.self) {
            try await repository.setMetadata(["data": value], of: ["a.txt"])
        }
        #expect(error?.code == .notSupported)
    }
}

@Suite struct DependencyTests {
    @Test func addAndListDependencies() async throws {
        let repository = try await makeOfflineRepository()
        for file in ["scene.txt", "mesh.txt", "texture.txt"] {
            try repository.write(file, to: file)
        }
        try await repository.stage(["."])

        #expect(try await repository.addDependencies(["mesh.txt"], to: "scene.txt", tags: ["geometry"]) == 1)
        #expect(try await repository.addDependencies(["texture.txt"], to: "mesh.txt") == 1)
        try await repository.commit(message: "Scene")

        let direct = try await repository.dependencies(of: ["scene.txt"])
        #expect(direct == [Dependency(path: "scene.txt", dependency: "mesh.txt", tags: ["geometry"], depth: 0)])

        let recursive = try await repository.dependencies(of: ["scene.txt"], recursive: true)
        #expect(recursive.map(\.dependency) == ["mesh.txt", "texture.txt"])
        #expect(recursive.map(\.depth) == [0, 1])

        let limited = try await repository.dependencies(of: ["scene.txt"], recursive: true, depthLimit: 1)
        #expect(limited.map(\.dependency) == ["mesh.txt"])

        let dependents = try await repository.dependents(of: ["texture.txt"])
        #expect(dependents == [Dependency(path: "mesh.txt", dependency: "texture.txt", tags: [], depth: 0)])

        let recursiveDependents = try await repository.dependents(of: ["texture.txt"], recursive: true)
        #expect(recursiveDependents.map(\.path) == ["mesh.txt", "scene.txt"])
        #expect(recursiveDependents.allSatisfy { $0.dependency == "texture.txt" })

        let tagged = try await repository.dependencies(of: ["scene.txt", "mesh.txt"], tags: ["geometry"])
        #expect(tagged.map(\.dependency) == ["mesh.txt"])
    }

    @Test func removeDependencies() async throws {
        let repository = try await makeOfflineRepository()
        for file in ["scene.txt", "mesh.txt", "texture.txt"] {
            try repository.write(file, to: file)
        }
        try await repository.stage(["."])
        try await repository.addDependencies(["mesh.txt", "texture.txt"], to: "scene.txt", tags: ["asset"])
        try await repository.commit(message: "Scene")

        try repository.write("scene, again", to: "scene.txt")
        try await repository.stage(["scene.txt"])
        #expect(try await repository.removeDependencies(["mesh.txt"], from: "scene.txt") == 1)
        #expect(try await repository.dependencies(of: ["scene.txt"]).map(\.dependency) == ["texture.txt"])
        #expect(try await repository.removeDependencies(["mesh.txt"], from: "scene.txt") == 0)
        try await repository.commit(message: "Remove mesh")
        #expect(try await repository.dependencies(of: ["scene.txt"], revision: "main@1").count == 2)
        #expect(try await repository.dependencies(of: ["scene.txt"], revision: "main@2").count == 1)
    }

    @Test func depthLimitMustBePositive() async throws {
        let repository = try await makeOfflineRepository()
        let error = await #expect(throws: LoreError.self) {
            try await repository.dependencies(of: ["a.txt"], recursive: true, depthLimit: 0)
        }
        #expect(error?.code == .invalidArguments)
    }
}
