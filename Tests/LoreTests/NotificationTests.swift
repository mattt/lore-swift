import Foundation
import Synchronization
import Testing

@testable import Lore

@Suite struct NotificationTests {
    @Test func offlineRepositoriesCannotSubscribe() async throws {
        let repository = try await makeOfflineRepository()
        let error = await #expect(throws: LoreError.self) {
            try await repository.notifications()
        }
        #expect(error?.code == .internal)
    }
}

/// Tests of notification subscriptions against a local server.
///
/// The suite is serialized because it counts the binding's calls to unsubscribe,
/// which are process-wide.
@Suite(.integration, .serialized) struct NotificationIntegrationTests {
    /// Collects the notifications of a stream in a task.
    private final class Collector: Sendable {
        private final class Storage: Sendable {
            let notifications = Mutex<[RepositoryNotification]>([])
        }

        private let storage: Storage
        private let task: Task<Void, Never>

        init(_ stream: AsyncStream<RepositoryNotification>) {
            let storage = Storage()
            self.storage = storage
            task = Task {
                for await notification in stream {
                    storage.notifications.withLock { $0.append(notification) }
                }
            }
        }

        var notifications: [RepositoryNotification] {
            storage.notifications.withLock { $0 }
        }

        /// Waits until the collector has a notification that matches,
        /// and returns it.
        func first(
            where predicate: (RepositoryNotification) -> Bool
        ) async throws -> RepositoryNotification? {
            try await eventually { notifications.first(where: predicate) }
        }

        /// Cancels the task that iterates the stream and waits for it to end.
        func cancel() async {
            task.cancel()
            await task.value
        }
    }

    /// A weak reference, to tell when the binding releases a channel.
    private final class WeakChannel: @unchecked Sendable {
        weak var channel: NotificationChannel?

        init(_ channel: NotificationChannel?) {
            self.channel = channel
        }
    }

    /// Calls `body` until it returns a value or 10 seconds pass.
    private static func eventually<T>(_ body: () async throws -> T?) async throws -> T? {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let value = try await body() {
                return value
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func eventually<T>(_ body: () async throws -> T?) async throws -> T? {
        try await Self.eventually(body)
    }

    /// Creates a repository on the server with one pushed revision,
    /// and a clone of it.
    private func makeRepositoryAndClone() async throws -> (alice: Repository, bob: Repository) {
        let path = temporaryRepositoryPath("notified")
        let url = "\(serverURL)/\(URL(filePath: path).lastPathComponent)"
        let alice = try await Repository.create(at: path, name: url, options: .init(identity: "alice@example.com"))
        try alice.write("hello\n", to: "a.txt")
        try await alice.stage(["a.txt"])
        try await alice.commit(message: "First")
        try await alice.push()
        let bob = try await Repository.clone(
            from: url,
            to: temporaryRepositoryPath("notified-clone"),
            options: .init(identity: "bob@example.com")
        )
        return (alice, bob)
    }

    /// Commits a change to `a.txt` and pushes it.
    @discardableResult
    private func commitAndPush(_ text: String, in repository: Repository) async throws -> Revision {
        try repository.write(text, to: "a.txt")
        try await repository.stage(["a.txt"])
        let revision = try await repository.commit(message: text)
        try await repository.push()
        return revision
    }

    /// Waits until the binding has unsubscribed from a repository
    /// and released its channel.
    private func expectUnsubscribed(_ repositoryID: RepositoryID, _ channel: WeakChannel) async throws {
        let subscriptions = NotificationSubscriptions.shared
        #expect(try await eventually { await subscriptions.channel(for: repositoryID) == nil ? true : nil } == true)
        #expect(try await eventually { channel.channel == nil ? true : nil } == true)
    }

    @Test func notificationsReportPushesBranchesAndLocks() async throws {
        let (alice, bob) = try await makeRepositoryAndClone()
        let collector = Collector(try await alice.notifications())
        let mainID = try #require(try await alice.status().branchID)

        let pushed = try await commitAndPush("from bob\n", in: bob)
        #expect(
            try await collector.first { if case .branchPushed = $0 { true } else { false } }
                == .branchPushed(branchID: mainID, revisionID: pushed.id, revisionNumber: 2, userID: "<unknown>")
        )

        try await bob.createBranch(named: "feature")
        try await bob.switchBranch(to: "feature")
        let featureID = try #require(try await bob.status().branchID)
        let feature = try await commitAndPush("feature\n", in: bob)
        #expect(try await collector.first { $0 == .branchCreated(branchID: featureID) } != nil)
        #expect(
            try await collector.first {
                $0 == .branchPushed(branchID: featureID, revisionID: feature.id, revisionNumber: 3, userID: "<unknown>")
            } != nil
        )

        try await bob.switchBranch(to: "main")
        try await bob.lock(["a.txt"])
        try await bob.unlock(["a.txt"])
        #expect(
            try await collector.first { $0 == .filesLocked(paths: ["a.txt"], branchID: mainID, userID: "<unknown>") }
                != nil
        )
        #expect(
            try await collector.first { $0 == .filesUnlocked(paths: ["a.txt"], branchID: mainID, userID: "<unknown>") }
                != nil
        )

        try await bob.archiveBranch(named: "feature")
        #expect(try await collector.first { $0 == .branchDeleted(branchID: featureID) } != nil)

        // The subscriber's own pushes are reported too.
        try await alice.sync()
        let own = try await commitAndPush("from alice\n", in: alice)
        #expect(
            try await collector.first {
                $0 == .branchPushed(branchID: mainID, revisionID: own.id, revisionNumber: 3, userID: "<unknown>")
            } != nil
        )

        let repositoryID = try await alice.state().repositoryID
        let channel = WeakChannel(await NotificationSubscriptions.shared.channel(for: repositoryID))
        let unsubscribeCount = await NotificationSubscriptions.shared.unsubscribeCount
        await collector.cancel()
        try await expectUnsubscribed(repositoryID, channel)
        #expect(await NotificationSubscriptions.shared.unsubscribeCount == unsubscribeCount + 1)
    }

    @Test func streamsForARepositoryShareOneSubscription() async throws {
        let (alice, bob) = try await makeRepositoryAndClone()
        let repositoryID = try await alice.state().repositoryID
        #expect(try await bob.state().repositoryID == repositoryID)
        let subscriptions = NotificationSubscriptions.shared
        let unsubscribeCount = await subscriptions.unsubscribeCount

        let first = Collector(try await alice.notifications())
        let channel = WeakChannel(await subscriptions.channel(for: repositoryID))
        #expect(channel.channel != nil)
        let second = Collector(try await bob.notifications())
        #expect(await subscriptions.channel(for: repositoryID) === channel.channel)

        let two = try await commitAndPush("two\n", in: bob)
        for collector in [first, second] {
            #expect(
                try await collector.first { if case .branchPushed(_, two.id, _, _) = $0 { true } else { false } } != nil
            )
        }

        // Ending one stream leaves the subscription to the other.
        await first.cancel()
        let three = try await commitAndPush("three\n", in: bob)
        #expect(
            try await second.first { if case .branchPushed(_, three.id, _, _) = $0 { true } else { false } } != nil
        )
        #expect(await subscriptions.channel(for: repositoryID) === channel.channel)
        #expect(await subscriptions.unsubscribeCount == unsubscribeCount)

        // Ending the last stream unsubscribes once and releases the callback context.
        await second.cancel()
        try await expectUnsubscribed(repositoryID, channel)
        #expect(await subscriptions.unsubscribeCount == unsubscribeCount + 1)

        // A new stream subscribes again,
        // and releasing it after its loop unsubscribes.
        let mainID = try #require(try await alice.status().branchID)
        let renewed: WeakChannel
        do {
            let stream = try await alice.notifications()
            renewed = WeakChannel(await subscriptions.channel(for: repositoryID))
            #expect(renewed.channel != nil)
            let four = try await commitAndPush("four\n", in: bob)
            let notification = await withTaskGroup(of: RepositoryNotification?.self) { group in
                group.addTask {
                    for await notification in stream {
                        return notification
                    }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(10))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            #expect(
                notification
                    == .branchPushed(branchID: mainID, revisionID: four.id, revisionNumber: 4, userID: "<unknown>")
            )
        }
        try await expectUnsubscribed(repositoryID, renewed)
        #expect(await subscriptions.unsubscribeCount == unsubscribeCount + 2)
    }
}
