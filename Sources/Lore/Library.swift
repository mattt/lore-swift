import CLore
import Foundation
import Synchronization

/// Process-wide information about and control of the Lore library.
public enum Library {
    /// The version of the loaded library,
    /// such as `0.11.0+1893-lore_v0.11.0__urc_main`.
    ///
    /// The version starts with the interface version
    /// and continues with `+` and the build name.
    public static var version: String {
        String(cString: lore_version())
    }

    /// The interface version of the header that the binding was built against,
    /// such as `0.11.0`.
    public static let interfaceVersion: String = LORE_INTERFACE_VERSION

    /// The directory where the library keeps its per-user data.
    public static var userDirectory: String {
        String(cString: lore_user_directory())
    }

    /// Shuts down the library,
    /// stopping its worker threads and releasing its resources.
    ///
    /// Call this at most once,
    /// after every operation has finished.
    /// The library rejects every operation after shutdown
    /// with ``LoreError/Code/shutDown``,
    /// and it can't be started again in the same process.
    ///
    /// - Throws: ``LoreError`` if the library reports a failure.
    public static func shutdown() throws {
        let status = lore_shutdown()
        if status != 0 {
            throw LoreError(code: .init(rawValue: status))
        }
    }
}

// MARK: - Logging

extension Library {
    /// The severity of a log message.
    public enum LogLevel: Int, Sendable, Hashable, Comparable, CaseIterable {
        /// The most detailed tracing messages.
        case trace = 1
        /// Debugging messages.
        case debug = 2
        /// Informational messages.
        case info = 3
        /// Warnings about unexpected but recoverable situations.
        case warning = 4
        /// Errors.
        case error = 5

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var cValue: lore_log_level_t {
            lore_log_level_t(rawValue: UInt32(rawValue))
        }
    }

    /// A log message that the library reports during an operation.
    public struct LogEntry: Sendable, Hashable {
        /// The severity of the message.
        public var level: LogLevel
        /// The text of the message.
        public var message: String
        /// The source location in the library that produced the message.
        public var location: String
        /// The time the library produced the message.
        public var date: Date
    }

    /// Sends the library's log messages at or above a level to a handler.
    ///
    /// The handler runs on a library thread,
    /// so it must return promptly and must be safe to call concurrently.
    /// Pass `nil` to stop handling log messages.
    ///
    /// - Parameters:
    ///   - level: The minimum level of the messages the library reports.
    ///   - handler: The function that receives each entry, or `nil`.
    /// - Throws: ``LoreError`` if the library rejects the configuration.
    public static func setLogHandler(
        level: LogLevel = .info,
        _ handler: (@Sendable (LogEntry) -> Void)?
    ) throws {
        let arena = Arena()
        let configuration = arena.allocate(lore_log_config_t.self)
        configuration.pointee.level = handler == nil ? LORE_LOG_LEVEL_NONE : level.cValue
        let status = withExtendedLifetime(arena) {
            lore_log_configure(configuration)
        }
        if status != 0 {
            throw LoreError(code: .init(rawValue: status))
        }
        LogHandler.current.withLock { $0 = handler }
    }
}

/// The process-wide handler for log events.
enum LogHandler {
    static let current = Mutex<(@Sendable (Library.LogEntry) -> Void)?>(nil)

    static func dispatch(_ data: lore_log_event_data_t) {
        guard let handler = current.withLock({ $0 }),
            let level = Library.LogLevel(rawValue: Int(data.level.rawValue))
        else {
            return
        }
        handler(
            Library.LogEntry(
                level: level,
                message: String(data.message),
                location: String(data.location),
                date: Date(millisecondsSince1970: data.timestamp)
            )
        )
    }
}
