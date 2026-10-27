import Foundation
import Testing

@testable import Lore

@Suite struct LoreErrorTests {
    @Test func descriptionIncludesMessageAndTrace() {
        let error = LoreError(
            code: .init(rawValue: 42),
            message: "something failed",
            trace: [
                .init(file: "src/repo.rs", line: 12, column: 4, context: "open"),
                .init(file: "src/main.rs", line: 3, column: 1),
            ]
        )
        #expect(
            error.description == """
                Lore error 42: something failed
                    at src/repo.rs:12:4 (open)
                    at src/main.rs:3:1
                """
        )
    }

    @Test func descriptionWithoutMessage() {
        let error = LoreError(code: .init(rawValue: 42))
        #expect(error.description == "Lore operation failed with code 42")
    }

    @Test func localizedDescriptionIsTheMessage() {
        let error: any Error = LoreError(code: .nothingStaged, message: "nothing to commit")
        #expect(error.localizedDescription == "nothing to commit")
        #expect(LoreError(code: .init(rawValue: 42)).localizedDescription == "Lore operation failed with code 42")
    }

    @Test(arguments: [
        (LoreError.Code.invalidArguments, LoreError.Category.invalidInput),
        (.notAuthorized, .authentication),
        (.slowDown, .connectivity),
        (.nothingStaged, .repositoryState),
        (.branchAlreadyExists, .alreadyExists),
        (.branchNotFound, .notFound),
        (.missingIdentity, .configuration),
        (.shutDown, .lifecycle),
        (.internal, .other),
        (.init(rawValue: 130), .other),
    ])
    func category(code: LoreError.Code, category: LoreError.Category) {
        #expect(code.category == category)
    }
}

@Suite struct IdentifierTests {
    @Test func revisionIDRoundTripsThroughHexadecimal() throws {
        let text = "1e44d056e12a8dea7e3d02c0fa3bc736c0fdfcaf908b200cba3a7d53aaf19dc2"
        let revision = try #require(RevisionID(text))
        #expect(revision.description == text)
        #expect(RevisionID(text.uppercased()) == revision)
        #expect(revision.bytes.first == 0x1e)
    }

    @Test(arguments: ["", "1e44", "zz" + String(repeating: "0", count: 62), String(repeating: "0", count: 63)])
    func revisionIDRejectsInvalidText(_ text: String) {
        #expect(RevisionID(text) == nil)
    }

    @Test func branchIDRoundTripsThroughHexadecimal() throws {
        let text = "00112233445566778899aabbccddeeff"
        let branch = try #require(BranchID(text))
        #expect(branch.description == text)
        #expect(BranchID(String(text.dropLast(2))) == nil)
        #expect(RepositoryID(text)?.description == text)
    }

    @Test func identifiersRequireTheirByteCount() {
        #expect(RevisionID(bytes: Array(repeating: 1, count: 31)) == nil)
        #expect(BranchID(bytes: Array(repeating: 1, count: 16)) != nil)
        #expect(RepositoryID(bytes: Array(repeating: 1, count: 17)) == nil)
    }
}

@Suite struct RevisionSpecifierTests {
    @Test func specifiersUseTheCommandLineForms() throws {
        let id = try #require(RevisionID(String(repeating: "ab", count: 32)))
        #expect(RevisionSpecifier.id(id).rawValue == id.description)
        #expect(RevisionSpecifier.number(3).rawValue == "@3")
        #expect(RevisionSpecifier.number(3, on: "main").rawValue == "main@3")
        #expect(RevisionSpecifier.latest().rawValue == "@LATEST")
        #expect(RevisionSpecifier.latest(on: "feature").rawValue == "feature@LATEST")
        #expect(("main@2" as RevisionSpecifier) == .number(2, on: "main"))
    }
}

@Suite struct MetadataValueTests {
    @Test func encodesValuesAsText() throws {
        #expect(MetadataValue.string("texture").encoded?.text == "texture")
        #expect(MetadataValue.number(42).encoded?.text == "42")
        #expect(MetadataValue.boolean(false).encoded?.text == "false")
        #expect(MetadataValue.hash(Array(repeating: 0xab, count: 2)).encoded?.text == "abab")
    }

    @Test func binaryAndAddressValuesHaveNoText() {
        #expect(MetadataValue.binary(Array("abc".utf8)).encoded == nil)
        #expect(MetadataValue.address(hash: [], context: []).encoded == nil)
    }
}
