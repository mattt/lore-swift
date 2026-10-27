import Testing

@testable import Lore

@Suite struct LibraryTests {
    @Test func versionStartsWithInterfaceVersion() {
        #expect(Library.interfaceVersion == "0.11.0")
        #expect(Library.version.hasPrefix(Library.interfaceVersion + "+"))
    }

    @Test func userDirectoryFollowsHome() {
        let home = isolatedHome
        #expect(Library.userDirectory.hasPrefix(home))
    }
}
