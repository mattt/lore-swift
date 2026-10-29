import CLore
import Foundation
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

/// Tests of the process-wide log handler,
/// which run one at a time because each sets the handler.
@Suite(.serialized) struct LoggingTests {
    @Test func handlerCanBeReplacedAfterManyMessages() throws {
        let messages = Messages()
        try Library.setLogHandler(level: .error) { messages.append($0) }
        defer { try? Library.setLogHandler(nil) }

        var data = lore_log_event_data_t()
        data.level = LORE_LOG_LEVEL_ERROR
        for _ in 0 ..< 100_000 {
            LogHandler.dispatch(data)
        }
        #expect(messages.count >= 100_000)
        try Library.setLogHandler(nil)
    }

    @Test func handlerReceivesLogMessages() async throws {
        let messages = Messages()
        try Library.setLogHandler(level: .debug) { messages.append($0) }
        defer { try? Library.setLogHandler(nil) }

        let start = Date()
        _ = try await makeOfflineRepository()
        #expect(messages.values.contains { $0.message.contains("repository::create") })
        #expect(messages.values.allSatisfy { $0.level >= .debug })
        #expect(messages.values.allSatisfy { abs($0.date.timeIntervalSince(start)) < 60 })
    }
}

/// Collects log messages from library threads.
private final class Messages: Sendable {
    private let storage = Mutex<[Library.LogEntry]>([])

    var values: [Library.LogEntry] {
        storage.withLock { $0 }
    }

    var count: Int {
        storage.withLock { $0.count }
    }

    func append(_ message: Library.LogEntry) {
        storage.withLock { $0.append(message) }
    }
}
