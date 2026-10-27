import Synchronization
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

@Suite struct LoggingTests {
    @Test func handlerReceivesLogMessages() async throws {
        let messages = Messages()
        try Library.setLogHandler(level: .debug) { messages.append($0) }
        defer { try? Library.setLogHandler(nil) }

        _ = try await makeOfflineRepository()
        #expect(messages.values.contains { $0.message.contains("repository::create") })
        #expect(messages.values.allSatisfy { $0.level >= .debug })
    }
}

/// Collects log messages from library threads.
private final class Messages: Sendable {
    private let storage = Mutex<[Library.LogMessage]>([])

    var values: [Library.LogMessage] {
        storage.withLock { $0 }
    }

    func append(_ message: Library.LogMessage) {
        storage.withLock { $0.append(message) }
    }
}
