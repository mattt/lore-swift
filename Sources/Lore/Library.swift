import CLore
import Foundation
import Synchronization

/// Process-wide information about and control of the Lore library.
public enum Library {
    /// The version of the loaded library,
    /// such as `0.12.0+1967`.
    ///
    /// The version starts with the interface version
    /// and continues with `+` and an identifier of the build.
    public static var version: String {
        String(cString: lore_version())
    }

    /// The interface version of the header that the binding was built against,
    /// such as `0.12.0`.
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

// MARK: - Process settings

extension Library {
    /// A codec that the library compresses content with before it stores it.
    ///
    /// Corresponds to `lore_compression_mode_t`.
    /// Stored content records its codec,
    /// so a mode decides how the library writes content,
    /// not how it reads content back.
    public struct CompressionMode: RawRepresentable, Sendable, Hashable {
        /// The raw value of the mode.
        public var rawValue: UInt32

        /// Creates a mode from its raw value.
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// No selection:
        /// the mode that the first server the process connects to prefers,
        /// or Zstandard.
        /// This is the default.
        public static let automatic = Self(rawValue: LORE_COMPRESSION_MODE_NOT_SPECIFIED.rawValue)

        /// No compression,
        /// for content that's already compressed.
        public static let uncompressed = Self(rawValue: LORE_COMPRESSION_MODE_NO_COMPRESSION.rawValue)

        /// LZ4, which takes less time than Zstandard and stores more bytes.
        public static let lz4 = Self(rawValue: LORE_COMPRESSION_MODE_LZ4.rawValue)

        /// Zstandard, at the level that ``Library/setCompressionLevel(_:)`` selects.
        public static let zstandard = Self(rawValue: LORE_COMPRESSION_MODE_ZSTD.rawValue)
    }

    /// Limits the number of threads that the library creates for its own work,
    /// for the whole process.
    ///
    /// The library divides the limit among its four thread pools
    /// and gives each pool at least 2 threads,
    /// so a limit below 8 yields 8.
    /// The limit doesn't count threads that your program creates.
    /// The environment variable `LORE_MAX_THREADS`,
    /// when it's set above 0,
    /// takes precedence over the limit.
    ///
    /// Call this method once, before the first operation of the process.
    /// The first call records the limit and returns `true`,
    /// in Lore 0.12.0 even after the first operation,
    /// and later calls return `false`.
    /// There's no way to read the limit back.
    ///
    /// - Parameter limit: The maximum number of threads,
    ///   or `nil` for no limit,
    ///   which sizes each pool for the number of processors.
    ///   A limit below 1 counts as 1.
    /// - Returns: `true` if the library recorded the limit,
    ///   or `false` if an earlier call had recorded one.
    @discardableResult
    public static func setThreadLimit(_ limit: Int?) -> Bool {
        let count = limit.map { UInt(clamping: max($0, 1)) } ?? 0
        return lore_set_thread_limit(count) == 0
    }

    /// Selects how the library compresses content that it stores,
    /// for every repository in the process.
    ///
    /// The mode applies to content that the process stores after the call,
    /// and you can call this method at any time.
    /// A mode that you select takes precedence over the mode that a server prefers.
    /// There's no way to read the mode back;
    /// select ``CompressionMode/automatic`` to restore the default.
    ///
    /// - Parameter mode: The mode.
    /// - Throws: ``LoreError`` with ``LoreError/Code/invalidArguments``
    ///   for a mode that the library doesn't support,
    ///   such as Oodle (raw value 3), which Lore 0.12.0 refuses.
    public static func setCompressionMode(_ mode: CompressionMode) throws {
        let status = lore_set_compression_mode(mode.rawValue)
        if status != 0 {
            throw LoreError(
                code: .init(rawValue: status),
                message: "The library doesn't support compression mode \(mode.rawValue)."
            )
        }
    }

    /// Selects the level at which the library compresses content,
    /// for every repository in the process.
    ///
    /// The level is a Zstandard level from 1 to 22,
    /// which trades time for size.
    /// A level of -1 selects each codec's default, as `nil` does.
    /// The library clamps other levels into the range that each codec accepts,
    /// so 0 selects the lowest level.
    /// The environment variable `LORE_COMPRESSION_LEVEL`
    /// takes precedence over the level
    /// when it names a level that the codec accepts.
    ///
    /// Call this method once, before the process stores any content.
    /// The library fixes the level at the first call of this method
    /// or when it first compresses content, whichever comes first,
    /// and ignores later calls.
    /// There's no way to read the level back.
    ///
    /// - Parameter level: The level,
    ///   or `nil` for each codec's default, which is 6 for Zstandard.
    /// - Returns: `true` if the library selected the level,
    ///   or `false` if it had already fixed the level.
    @discardableResult
    public static func setCompressionLevel(_ level: Int?) -> Bool {
        lore_set_compression_level(level.map { Int32(clamping: $0) } ?? -1) == 0
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
        LogHandler.current.withLock { $0 = handler.map(LogHandler.init) }
    }
}

/// The process-wide handler for log events.
///
/// The mutex holds the closure inside a structure.
/// When the mutex held the closure itself,
/// each read with `withLock` nested the stored closure
/// in more reabstraction thunks,
/// and after many log events, releasing it overflowed the stack.
struct LogHandler: Sendable {
    static let current = Mutex<LogHandler?>(nil)

    let handle: @Sendable (Library.LogEntry) -> Void

    init(_ handle: @escaping @Sendable (Library.LogEntry) -> Void) {
        self.handle = handle
    }

    static func dispatch(_ data: lore_log_event_data_t) {
        guard let handler = current.withLock({ $0?.handle }),
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
