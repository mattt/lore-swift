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
        try await repository.setMetadata(values, forPaths: ["a.txt"])
        for (key, value) in values {
            #expect(try await repository.metadata(forKey: key, path: "a.txt") == value)
        }
        #expect(try await repository.metadata(forKey: "missing", path: "a.txt") == nil)
    }

    @Test func metadataIsPartOfTheCommit() async throws {
        let repository = try await repositoryWithStagedFile()
        try await repository.setMetadata(["kind": .string("texture")], forPaths: ["a.txt"])
        let revision = try await repository.commit(message: "Second")

        #expect(try await repository.metadata(forKey: "kind", path: "a.txt", revision: "main@2") == .string("texture"))
        #expect(
            try await repository.metadata(forKey: "kind", path: "a.txt", revision: revision.id.description)
                == .string("texture")
        )
        #expect(try await repository.metadata(forKey: "kind", path: "a.txt", revision: "main@1") == nil)
    }

    @Test func setsValuesOnSeveralFiles() async throws {
        let repository = try await repositoryWithStagedFile()
        try repository.write("world, again\n", to: "b.txt")
        try await repository.stage(["b.txt"])
        try await repository.setMetadata(["kind": .string("text"), "lines": .number(1)], forPaths: ["a.txt", "b.txt"])
        for path in ["a.txt", "b.txt"] {
            #expect(try await repository.metadata(forKey: "kind", path: path) == .string("text"))
            #expect(try await repository.metadata(forKey: "lines", path: path) == .number(1))
        }
    }

    @Test(arguments: [MetadataValue.binary([0xff, 0xfe]), .address(hash: [], context: [])])
    func refusesValuesTheBindingCannotSet(value: MetadataValue) async throws {
        let repository = try await repositoryWithStagedFile()
        let error = await #expect(throws: LoreError.self) {
            try await repository.setMetadata(["data": value], forPaths: ["a.txt"])
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

        let dependents = try await repository.dependencies(of: ["texture.txt"], dependents: true)
        #expect(dependents.map(\.dependency) == ["mesh.txt"])

        let limited = try await repository.dependencies(of: ["scene.txt"], recursive: true, depthLimit: 1)
        #expect(limited.map(\.dependency) == ["mesh.txt"])

        let tagged = try await repository.dependencies(of: ["scene.txt", "mesh.txt"], tags: ["geometry"])
        #expect(tagged.map(\.dependency) == ["mesh.txt"])
    }

    @Test func depthLimitMustBePositive() async throws {
        let repository = try await makeOfflineRepository()
        let error = await #expect(throws: LoreError.self) {
            try await repository.dependencies(of: ["a.txt"], recursive: true, depthLimit: 0)
        }
        #expect(error?.code == .invalidArguments)
    }
}
