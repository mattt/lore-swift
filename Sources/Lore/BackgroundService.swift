import CLore
import Foundation

/// Control of the Lore background service:
/// a process that carries out Lore operations for other processes on this computer.
///
/// The service is a separate executable,
/// such as the `lore` command-line tool,
/// that the library starts with the arguments `service run`.
/// The library starts it in its own session,
/// so it keeps running after the process that started it exits,
/// until ``stop(force:)`` stops it.
/// Clients reach it over a Unix domain socket named `lore_service`
/// in the directory `lore-<user ID>` inside `$XDG_RUNTIME_DIR`,
/// or `$TMPDIR` when that isn't set.
/// Set `LORE_SERVICE_SOCKET` in the environment to another file name
/// to use a service of your own in that directory.
///
/// The settings that ``setExecutable(_:)`` and ``setUsedAutomatically(_:)`` change
/// are in the user's global Lore configuration,
/// `config.toml` in ``Library/userDirectory``,
/// or in the `config` subdirectory of `$LORE_GLOBAL_PATH` when that's set.
/// They apply to every process of the user that uses the library,
/// including other programs and the `lore` command-line tool.
/// The environment variables `LORE_SERVICE_EXECUTABLE` and `LORE_USE_SERVICE`
/// take precedence over them.
public enum BackgroundService {}

extension BackgroundService {
    /// The state of the background service.
    public struct Status: Sendable, Hashable {
        /// A Boolean value that indicates whether a service is running
        /// and answers on the socket.
        public var isRunning: Bool

        /// The path of the service's executable,
        /// or `nil` if no service is running.
        public var executablePath: String?

        /// The time since the service started,
        /// or zero if no service is running.
        public var uptime: Duration

        /// The number of clients connected to the service.
        public var connectionCount: Int

        /// The number of virtual file system mounts that the service serves.
        public var mountCount: Int

        /// The log messages that the service recorded
        /// while it wasn't carrying out an operation.
        ///
        /// The service discards each message once it reports it,
        /// so the next status doesn't include it.
        public var messages: [Message]
    }

    /// A log message that the background service recorded.
    public struct Message: Sendable, Hashable {
        /// The severity of the message.
        public var level: Library.LogLevel

        /// The text of the message.
        public var text: String
    }
}

extension BackgroundService {
    /// Starts the background service, unless one is already running.
    ///
    /// The library starts the executable that `LORE_SERVICE_EXECUTABLE`
    /// or ``setExecutable(_:)`` names,
    /// and waits up to 10 seconds for it to answer.
    /// The service keeps running after this process exits;
    /// call ``stop(force:)`` to stop it.
    ///
    /// - Throws: ``LoreError`` with ``LoreError/Code/serviceUnavailable``
    ///   if no service answers,
    ///   such as when no executable is set
    ///   or the executable can't be started.
    public static func start() async throws {
        _ = try await context.perform(
            lore_service_start_async,
            configure: { (_: UnsafeMutablePointer<lore_service_start_args_t>, _) in },
            transform: { _ -> Never? in nil }
        )
    }

    /// Stops the running background service.
    ///
    /// The method doesn't start a service in order to stop it,
    /// and it succeeds if no service is running.
    /// It returns once the service no longer answers on the socket.
    ///
    /// - Parameter force: Whether to detach virtual file system mounts
    ///   that something still uses.
    ///   Without it, the service refuses to stop while it has such a mount.
    /// - Throws: ``LoreError`` if the service refuses to stop,
    ///   such as ``LoreError/Code/mountsBusy``,
    ///   or doesn't stop in time.
    public static func stop(force: Bool = false) async throws {
        _ = try await context.perform(
            lore_service_stop_async,
            force: force,
            configure: { (_: UnsafeMutablePointer<lore_service_stop_args_t>, _) in },
            transform: { _ -> Never? in nil }
        )
    }

    /// Reports whether the background service is running,
    /// with details of the service that is.
    ///
    /// The method doesn't start a service.
    ///
    /// - Returns: The state of the service.
    /// - Throws: ``LoreError`` if the library can't look for a service.
    public static func status() async throws -> Status {
        let events = try await context.perform(
            lore_service_status_async,
            configure: { (_: UnsafeMutablePointer<lore_service_status_args_t>, _) in },
            transform: ServiceEvent.init
        )
        var status: Status?
        var messages: [Message] = []
        for event in events {
            switch event {
            case .status(let value):
                status = value
            case .message(let message):
                messages.append(message)
            }
        }
        guard var status else {
            throw LoreError.missingEvent("the service status")
        }
        status.messages = messages
        return status
    }

    /// Names the executable that the library starts as the background service,
    /// for every process of the user.
    ///
    /// The method writes the setting to the user's global Lore configuration.
    /// Pass `nil` to remove it,
    /// which restores the default:
    /// then the library can't start a service,
    /// but it still uses one that is running.
    ///
    /// - Parameter path: The path of the executable, or `nil`.
    /// - Throws: ``LoreError`` if the library can't write the configuration.
    public static func setExecutable(_ path: String?) async throws {
        _ = try await context.perform(
            lore_service_set_executable_async,
            configure: { (arguments: UnsafeMutablePointer<lore_service_set_executable_args_t>, arena) in
                arguments.pointee.executable = arena.string(path)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Sets whether the library carries out operations in the background service
    /// instead of in the process that calls them,
    /// for every process of the user.
    ///
    /// The method writes the setting to the user's global Lore configuration.
    /// While it's on,
    /// each operation starts a service if none is running,
    /// and fails with ``LoreError/Code/serviceUnavailable``
    /// if the library can't start one.
    /// Pass `false` to restore the default.
    ///
    /// - Parameter enabled: Whether to carry out operations in the service.
    /// - Throws: ``LoreError`` if the library can't write the configuration.
    public static func setUsedAutomatically(_ enabled: Bool) async throws {
        _ = try await context.perform(
            lore_service_set_use_automatically_async,
            configure: {
                (arguments: UnsafeMutablePointer<lore_service_set_use_automatically_args_t>, _) in
                arguments.pointee.enabled = UInt8(enabled)
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// The context for calls that don't belong to a repository.
    private static var context: Repository {
        Repository(path: "")
    }
}

/// An event of a service status call.
private enum ServiceEvent: Sendable {
    case status(BackgroundService.Status)
    case message(BackgroundService.Message)

    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_SERVICE_STATUS.rawValue:
            let data = event.pointee.service_status
            let executablePath = String(data.binary_path)
            self = .status(
                BackgroundService.Status(
                    isRunning: Bool(data.running),
                    executablePath: executablePath.isEmpty ? nil : executablePath,
                    uptime: .milliseconds(data.uptime_ms),
                    connectionCount: Int(data.connection_count),
                    mountCount: Int(data.swfs_mount_count),
                    messages: []
                )
            )
        case LORE_EVENT_SERVICE_MESSAGE.rawValue:
            let data = event.pointee.service_message
            self = .message(
                BackgroundService.Message(
                    level: Library.LogLevel(rawValue: Int(data.level.rawValue)) ?? .info,
                    text: String(data.message)
                )
            )
        default:
            return nil
        }
    }
}
