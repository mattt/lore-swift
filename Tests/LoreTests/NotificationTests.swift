import Foundation
import Synchronization
import Testing

@testable import Lore

/// The error that ``withTimeLimit(_:_:)`` throws when the time runs out.
struct TimeLimitExceeded: Error {}

/// Runs an operation and throws ``TimeLimitExceeded`` if it doesn't end in time,
/// so that a test that hangs fails instead of stalling the suite.
///
/// The operation runs in an unstructured task,
/// which keeps running if the time runs out.
func withTimeLimit<T: Sendable>(
    _ limit: Duration = .seconds(10),
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = TimeLimitOutcome<T>()
    return try await withCheckedThrowingContinuation { continuation in
        outcome.wait(with: continuation)
        Task {
            do {
                outcome.finish(.success(try await operation()))
            } catch {
                outcome.finish(.failure(error))
            }
        }
        Task {
            try? await Task.sleep(for: limit)
            outcome.finish(.failure(TimeLimitExceeded()))
        }
    }
}

/// The continuation of a call to ``withTimeLimit(_:_:)``,
/// which the first result to arrive resumes.
private final class TimeLimitOutcome<T: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<T, any Error>?>(nil)

    func wait(with continuation: CheckedContinuation<T, any Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    func finish(_ result: Result<T, any Error>) {
        continuation.withLock { $0.take() }?.resume(with: result)
    }
}

@Suite struct NotificationTests {
    @Test func offlineRepositoriesCannotSubscribe() async throws {
        let repository = try await makeOfflineRepository()
        let error = await #expect(throws: LoreError.self) {
            try await repository.notifications()
        }
        #expect(error?.code == .internal)
    }
}

/// Tests of the order of subscribe and unsubscribe calls,
/// with operations that stand in for the library's and that the tests hold open.
@Suite struct NotificationSubscriptionsTests {
    /// A signal that tasks wait for until it opens.
    private final class Gate: Sendable {
        private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

        func open() {
            let waiters = state.withLock { state in
                state.isOpen = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters {
                waiter.resume()
            }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let isOpen = state.withLock { state in
                    if !state.isOpen {
                        state.waiters.append(continuation)
                    }
                    return state.isOpen
                }
                if isOpen {
                    continuation.resume()
                }
            }
        }
    }

    /// A count that tasks increment.
    private final class Counter: Sendable {
        private let count = Mutex(0)

        var value: Int {
            count.withLock { $0 }
        }

        func increment() {
            count.withLock { $0 += 1 }
        }
    }

    /// Strings that tasks record.
    private final class Recorder: Sendable {
        private let storage = Mutex<[String]>([])

        var values: [String] {
            storage.withLock { $0 }
        }

        func append(_ value: String) {
            storage.withLock { $0.append(value) }
        }
    }

    private let repository = Repository(path: "/nonexistent")
    private let repositoryID = RepositoryID(bytes: Array(repeating: 7, count: 16))!

    /// Waits until a condition holds, failing after 10 seconds.
    private func expectEventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        try await withTimeLimit {
            while await !condition() {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    @Test func joinsDuringTheSubscribeCallShareOneSubscription() async throws {
        let subscribed = Counter()
        let unsubscribed = Counter()
        let started = Gate()
        let release = Gate()
        let subscriptions = NotificationSubscriptions(
            subscribe: { _ in
                subscribed.increment()
                started.open()
                await release.wait()
            },
            unsubscribe: { _ in unsubscribed.increment() }
        )
        let repository = repository
        let repositoryID = repositoryID
        try await withTimeLimit {
            async let first = subscriptions.join(repository, repositoryID: repositoryID)
            await started.wait()
            async let second = subscriptions.join(repository, repositoryID: repositoryID)
            // Let the second call reach the wait for the subscribe call.
            try await Task.sleep(for: .milliseconds(100))
            release.open()
            let streams = try await (first, second)
            #expect(await subscriptions.channel(for: repositoryID) != nil)
            withExtendedLifetime(streams) {}
        }
        #expect(subscribed.value == 1)

        // Both streams are released together; the binding unsubscribes once.
        try await expectEventually { await subscriptions.channel(for: repositoryID) == nil }
        #expect(unsubscribed.value == 1)
        #expect(await subscriptions.unsubscribeCount == 1)
    }

    @Test func joinDuringTheUnsubscribeCallSubscribesAgain() async throws {
        let subscribed = Counter()
        let unsubscribed = Counter()
        let started = Gate()
        let release = Gate()
        let renewing = Gate()
        let subscriptions = NotificationSubscriptions(
            subscribe: { _ in
                subscribed.increment()
                // The second subscribe call stays open for a while,
                // so that the first call's continuation runs while it does.
                if subscribed.value == 2 {
                    await renewing.wait()
                }
            },
            unsubscribe: { _ in
                unsubscribed.increment()
                started.open()
                await release.wait()
            }
        )
        let repository = repository
        let repositoryID = repositoryID
        try await withTimeLimit {
            // Releasing the only stream starts the unsubscribe call.
            _ = try await subscriptions.join(repository, repositoryID: repositoryID)
            let ending = await subscriptions.channel(for: repositoryID)
            #expect(ending != nil)
            await started.wait()
            async let renewed = subscriptions.join(repository, repositoryID: repositoryID)
            // Let the call reach the wait for the unsubscribe call.
            try await Task.sleep(for: .milliseconds(100))
            release.open()
            try await Task.sleep(for: .milliseconds(100))
            renewing.open()
            let stream = try await renewed
            let channel = await subscriptions.channel(for: repositoryID)
            #expect(channel != nil)
            #expect(channel !== ending)
            withExtendedLifetime(stream) {}
        }
        #expect(subscribed.value == 2)

        // Releasing the renewed stream unsubscribes again.
        try await expectEventually { unsubscribed.value == 2 }
    }

    @Test func aFailedSubscribeCallLeavesTheRetryOfAWaitingJoin() async throws {
        let subscribed = Counter()
        let started = Gate()
        let release = Gate()
        let retrying = Gate()
        let unsubscribed = Counter()
        let subscriptions = NotificationSubscriptions(
            subscribe: { _ in
                subscribed.increment()
                if subscribed.value == 1 {
                    started.open()
                    await release.wait()
                    throw LoreError(code: .internal, message: "notifications not available when offline")
                }
                // The retry stays open for a while,
                // so that the failed call's continuation runs while it does.
                await retrying.wait()
            },
            unsubscribe: { _ in unsubscribed.increment() }
        )
        let repository = repository
        let repositoryID = repositoryID
        try await withTimeLimit {
            async let first = Result { try await subscriptions.join(repository, repositoryID: repositoryID) }
            await started.wait()
            async let second = Result { try await subscriptions.join(repository, repositoryID: repositoryID) }
            try await Task.sleep(for: .milliseconds(100))
            release.open()
            try await Task.sleep(for: .milliseconds(100))
            retrying.open()
            let (failed, retried) = await (first, second)
            #expect(throws: LoreError.self) { try failed.get() }
            // The waiting call finds no subscription and subscribes itself.
            let stream = try retried.get()
            #expect(await subscriptions.channel(for: repositoryID) != nil)
            withExtendedLifetime(stream) {}
        }
        #expect(subscribed.value == 2)
        try await expectEventually { unsubscribed.value == 1 }
    }

    @Test(arguments: [nil, LoreError(code: .internal, message: "The stream broke.")])
    func aSubscriptionThatTheLibraryEndsFinishesItsStreams(error: LoreError?) async throws {
        let unsubscribed = Counter()
        let subscriptions = NotificationSubscriptions(
            subscribe: { _ in },
            unsubscribe: { _ in unsubscribed.increment() }
        )
        let repository = repository
        let repositoryID = repositoryID
        let thrown = try await withTimeLimit {
            let stream = try await subscriptions.join(repository, repositoryID: repositoryID)
            let channel = try #require(await subscriptions.channel(for: repositoryID))
            channel.end(error)
            let notifications = await Result {
                var notifications: [RepositoryNotification] = []
                for try await notification in stream {
                    notifications.append(notification)
                }
                return notifications
            }
            #expect((try? notifications.get())?.isEmpty ?? true)
            return notifications.error
        }
        #expect(thrown as? LoreError == error)
        // The library ended the subscription, so the binding doesn't unsubscribe.
        try await expectEventually { await subscriptions.channel(for: repositoryID) == nil }
        #expect(unsubscribed.value == 0)
    }

    @Test func aChannelKeepsTheRepositoryPathAsItResolvedWhenItJoined() async throws {
        let absolute = try await makeOfflineRepository()
        let currentDirectory = FileManager.default.currentDirectoryPath
        let relativePath = try #require(
            absolute.path.hasPrefix(currentDirectory + "/")
                ? String(absolute.path.dropFirst(currentDirectory.count + 1)) : nil,
            "The scratch directory isn't under the current directory, \(currentDirectory)."
        )
        let relative = Repository(path: relativePath, options: absolute.options)
        let paths = Recorder()
        let subscriptions = NotificationSubscriptions(
            subscribe: { channel in paths.append(channel.repository.path) },
            unsubscribe: { channel in paths.append(channel.repository.path) }
        )
        try await withTimeLimit {
            let stream = try await relative.notifications(from: subscriptions)
            withExtendedLifetime(stream) {}
        }
        try await expectEventually { paths.values.count == 2 }
        #expect(paths.values == [absolute.path, absolute.path])
    }
}

extension Result where Failure == any Error {
    /// Captures the result of an asynchronous throwing operation.
    fileprivate init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }

    /// The error, or `nil` for a success.
    fileprivate var error: (any Error)? {
        if case .failure(let error) = self { error } else { nil }
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

        init(_ stream: AsyncThrowingStream<RepositoryNotification, any Error>) {
            let storage = Storage()
            self.storage = storage
            task = Task {
                do {
                    for try await notification in stream {
                        storage.notifications.withLock { $0.append(notification) }
                    }
                } catch {
                    Issue.record(error, "The notification stream threw.")
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
                == .branchPushed(branchID: mainID, revision: pushed.id, revisionNumber: 2, userID: "<unknown>")
        )

        try await bob.createBranch(named: "feature")
        try await bob.switchBranch(to: "feature")
        let featureID = try #require(try await bob.status().branchID)
        let feature = try await commitAndPush("feature\n", in: bob)
        #expect(try await collector.first { $0 == .branchCreated(branchID: featureID) } != nil)
        #expect(
            try await collector.first {
                $0 == .branchPushed(branchID: featureID, revision: feature.id, revisionNumber: 3, userID: "<unknown>")
            } != nil
        )

        try await bob.switchBranch(to: "main")
        // Each notification arrives before the next operation,
        // so the lock can't be reported as the unlock.
        try await bob.lock(["a.txt"])
        #expect(
            try await collector.first { $0 == .filesLocked(paths: ["a.txt"], branchID: mainID, userID: "<unknown>") }
                != nil
        )
        #expect(!collector.notifications.contains { if case .filesUnlocked = $0 { true } else { false } })
        try await bob.unlock(["a.txt"])
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
                $0 == .branchPushed(branchID: mainID, revision: own.id, revisionNumber: 3, userID: "<unknown>")
            } != nil
        )

        let repositoryID = try await alice.state().repositoryID
        let channel = WeakChannel(await NotificationSubscriptions.shared.channel(for: repositoryID))
        let unsubscribeCount = await NotificationSubscriptions.shared.unsubscribeCount
        await collector.cancel()
        try await expectUnsubscribed(repositoryID, channel)
        #expect(await NotificationSubscriptions.shared.unsubscribeCount == unsubscribeCount + 1)
    }

    @Test func overlappingCallsShareOneSubscription() async throws {
        let (alice, bob) = try await makeRepositoryAndClone()
        let repositoryID = try await alice.state().repositoryID
        let subscriptions = NotificationSubscriptions.shared
        let unsubscribeCount = await subscriptions.unsubscribeCount

        // The second call starts while the first one subscribes.
        let (first, second) = try await withTimeLimit {
            async let first = alice.notifications()
            async let second = bob.notifications()
            return try await (Collector(first), Collector(second))
        }
        let channel = WeakChannel(await subscriptions.channel(for: repositoryID))
        let pushed = try await commitAndPush("two\n", in: bob)
        for collector in [first, second] {
            #expect(
                try await collector.first { if case .branchPushed(_, pushed.id, _, _) = $0 { true } else { false } }
                    != nil
            )
        }

        // Both streams end together; the binding unsubscribes once.
        try await withTimeLimit {
            async let endFirst: Void = first.cancel()
            async let endSecond: Void = second.cancel()
            _ = await (endFirst, endSecond)
        }
        try await expectUnsubscribed(repositoryID, channel)
        #expect(await subscriptions.unsubscribeCount == unsubscribeCount + 1)
    }

    @Test func subscribingWhileTheLastStreamEnds() async throws {
        let (alice, bob) = try await makeRepositoryAndClone()
        let repositoryID = try await alice.state().repositoryID
        let first = Collector(try await alice.notifications())

        // A new call starts while the only stream ends.
        let renewed = try await withTimeLimit {
            async let ended: Void = first.cancel()
            async let renewed = alice.notifications()
            await ended
            return Collector(try await renewed)
        }
        let pushed = try await commitAndPush("two\n", in: bob)
        #expect(
            try await renewed.first { if case .branchPushed(_, pushed.id, _, _) = $0 { true } else { false } } != nil
        )
        let channel = WeakChannel(await NotificationSubscriptions.shared.channel(for: repositoryID))
        #expect(channel.channel != nil)
        try await withTimeLimit { await renewed.cancel() }
        try await expectUnsubscribed(repositoryID, channel)
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
                    do {
                        for try await notification in stream {
                            return notification
                        }
                    } catch {
                        Issue.record(error, "The notification stream threw.")
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
                    == .branchPushed(branchID: mainID, revision: four.id, revisionNumber: 4, userID: "<unknown>")
            )
        }
        try await expectUnsubscribed(repositoryID, renewed)
        #expect(await subscriptions.unsubscribeCount == unsubscribeCount + 2)
    }
}
