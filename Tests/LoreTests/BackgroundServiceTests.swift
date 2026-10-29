import Foundation
import Testing

@testable import Lore

/// Tests of the background service.
///
/// No test starts a service:
/// the package has no executable that can run one,
/// and a service would keep running in its own session after the tests,
/// with its socket outside the scratch directory.
/// Every call to ``BackgroundService/start()`` here
/// fails before the library starts a process.
/// The tests use a socket name of their own (see ``isolatedHome``),
/// so they never reach a service that the user runs.
///
/// The tests that change the service settings run in child processes
/// (exit tests) with a global configuration of their own,
/// because the settings change how every operation in a process runs.
@Suite(.serialized) struct BackgroundServiceTests {
    @Test func statusReportsNoService() async throws {
        _ = isolatedHome
        let status = try await BackgroundService.status()
        #expect(!status.isRunning)
        #expect(status.executablePath == nil)
        #expect(status.uptime == .zero)
        #expect(status.connectionCount == 0)
        #expect(status.mountCount == 0)
        #expect(status.messages.isEmpty)
    }

    @Test func stopSucceedsWithoutAService() async throws {
        _ = isolatedHome
        try await BackgroundService.stop()
        try await BackgroundService.stop(force: true)
        #expect(try await BackgroundService.status().isRunning == false)
    }

    @Test func executableSettingIsInTheGlobalConfiguration() async {
        await #expect(processExitsWith: .success) {
            let global = isolateGlobalDirectory()
            let configuration = "\(global)/config/config.toml"

            let unset = await #expect(throws: LoreError.self) {
                try await BackgroundService.start()
            }
            #expect(unset?.code == .serviceUnavailable)
            #expect(unset?.message.contains("no service executable set") == true)

            // The executable doesn't exist, so the library can't start a process.
            let executable = "\(global)/missing/lore"
            try await BackgroundService.setExecutable(executable)
            let text = try String(contentsOfFile: configuration, encoding: .utf8)
            #expect(text.contains("[service]\nexecutable = \"\(executable)\""))
            let missing = await #expect(throws: LoreError.self) {
                try await BackgroundService.start()
            }
            #expect(missing?.code == .serviceUnavailable)
            #expect(missing?.message.contains("No such file or directory") == true)
            #expect(try await BackgroundService.status().isRunning == false)

            try await BackgroundService.setExecutable(nil)
            #expect(try !String(contentsOfFile: configuration, encoding: .utf8).contains("executable"))
        }
    }

    @Test func automaticUseSendsOperationsToTheService() async {
        await #expect(processExitsWith: .success) {
            let global = isolateGlobalDirectory()
            let configuration = "\(global)/config/config.toml"

            try await BackgroundService.setUsedAutomatically(true)
            let text = try String(contentsOfFile: configuration, encoding: .utf8)
            #expect(text.contains("[service]\nuse_automatically = true"))

            // No service is running, and the library can't start one without an executable.
            let error = await #expect(throws: LoreError.self) {
                try await makeOfflineRepository()
            }
            #expect(error?.code == .serviceUnavailable)

            try await BackgroundService.setUsedAutomatically(false)
            #expect(try !String(contentsOfFile: configuration, encoding: .utf8).contains("use_automatically"))
            #expect(try await makeOfflineRepository().status().branch == "main")
        }
    }
}
