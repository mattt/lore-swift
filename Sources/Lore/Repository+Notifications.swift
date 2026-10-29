import CLore
import Synchronization

/// A change on the server that a notification subscription reports.
///
/// Later versions of the package can add cases
/// for the kinds of notification that later versions of Lore add,
/// so include a `default` case in a `switch` over a notification.
public enum RepositoryNotification: Sendable, Hashable {
    /// A branch was created.
    case branchCreated(branchID: BranchID)

    /// A branch was archived or deleted.
    case branchDeleted(branchID: BranchID)

    /// A push made a revision the latest revision of a branch.
    ///
    /// - Parameters:
    ///   - branchID: The branch.
    ///   - revision: The new latest revision of the branch.
    ///   - revisionNumber: The number of the revision on the branch.
    ///   - userID: The identifier of the user who pushed,
    ///     or `<unknown>` for a server that doesn't authenticate its users.
    case branchPushed(branchID: BranchID, revision: RevisionID, revisionNumber: Int, userID: String)

    /// A user locked files.
    ///
    /// - Parameters:
    ///   - paths: The paths of the files, relative to the repository directory.
    ///   - branchID: The branch that the locks belong to.
    ///   - userID: The identifier of the user who holds the locks,
    ///     or `<unknown>` for a server that doesn't authenticate its users.
    case filesLocked(paths: [String], branchID: BranchID?, userID: String)

    /// A user released locks on files.
    ///
    /// - Parameters:
    ///   - paths: The paths of the files, relative to the repository directory.
    ///   - branchID: The branch that the locks belonged to.
    ///   - userID: The identifier of the user who released the locks,
    ///     or `<unknown>` for a server that doesn't authenticate its users.
    case filesUnlocked(paths: [String], branchID: BranchID?, userID: String)
}

extension Repository {
    /// Subscribes to the notifications that the server sends
    /// when the repository changes,
    /// such as when someone pushes a branch or locks files.
    ///
    /// The method returns once the subscription is established,
    /// and the stream yields each notification that the server sends after that,
    /// including the notifications for your own pushes and locks.
    ///
    /// ```swift
    /// for try await notification in try await repository.notifications() {
    ///     if case .branchPushed(_, let revision, _, let userID) = notification {
    ///         print(userID, "pushed", revision)
    ///     }
    /// }
    /// ```
    ///
    /// The subscription lasts until the stream terminates:
    /// when the task that iterates it is cancelled,
    /// when the stream and its iterator are released,
    /// or when the server ends the subscription,
    /// which finishes the stream.
    /// The type of the stream allows an error,
    /// but in Lore 0.12.0 a subscription that the server ends,
    /// such as when the server stops,
    /// finishes the stream without one.
    /// The library keeps one subscription for each repository in a process,
    /// so every stream for the repository,
    /// including the streams of its clones in the same process,
    /// shares it,
    /// and the binding ends it when the last of them terminates.
    ///
    /// - Returns: A stream of notifications.
    /// - Throws: ``LoreError`` if the library can't subscribe.
    ///   Lore 0.12.0 reports an offline repository with ``LoreError/Code/internal``.
    public func notifications() async throws -> AsyncThrowingStream<RepositoryNotification, any Error> {
        try await notifications(from: .shared)
    }

    /// Joins a repository's subscription in the given subscriptions.
    func notifications(
        from subscriptions: NotificationSubscriptions
    ) async throws -> AsyncThrowingStream<RepositoryNotification, any Error> {
        // The subscription outlives this call,
        // so the library calls that start and end it use the path as it resolves now.
        let repository = Repository(path: absolutePath, options: options)
        let repositoryID = try await repository.state().repositoryID
        return try await subscriptions.join(repository, repositoryID: repositoryID)
    }
}

// MARK: - Implementation

/// The notification subscriptions of the process, one for each repository.
///
/// The library keeps one subscription for each repository identifier in a process:
/// subscribing again while one is active succeeds without delivering any events,
/// and unsubscribing ends the subscription for every caller.
/// The actor shares one library subscription among the streams for a repository,
/// and orders the library calls for it,
/// so that a new subscription never starts while an earlier one is ending.
actor NotificationSubscriptions {
    static let shared = NotificationSubscriptions()

    private enum Phase {
        /// The library call that subscribes is in progress.
        case opening(Task<Void, any Error>)
        /// The subscription is established.
        case open
        /// The library call that unsubscribes is in progress.
        case closing(Task<Void, Never>)
    }

    private struct Entry {
        var channel: NotificationChannel
        var phase: Phase
    }

    private var entries: [RepositoryID: Entry] = [:]

    /// The operation that subscribes a channel.
    private let subscribe: @Sendable (NotificationChannel) async throws -> Void

    /// The operation that unsubscribes a channel.
    private let unsubscribe: @Sendable (NotificationChannel) async -> Void

    /// The number of times the actor has asked the library to unsubscribe,
    /// for tests.
    private(set) var unsubscribeCount = 0

    /// Creates the subscriptions of a process.
    ///
    /// Tests replace the operations that call the library
    /// with operations that they control.
    init(
        subscribe: @escaping @Sendable (NotificationChannel) async throws -> Void = { try await $0.subscribe() },
        unsubscribe: @escaping @Sendable (NotificationChannel) async -> Void = { await $0.unsubscribe() }
    ) {
        self.subscribe = subscribe
        self.unsubscribe = unsubscribe
    }

    /// Returns a stream of the notifications for a repository,
    /// subscribing first if no stream for the repository is active.
    ///
    /// A caller that waits for another caller's library call
    /// applies the change of phase itself before it looks again,
    /// because awaiting a finished task doesn't give up the actor,
    /// so the other caller might not run first.
    func join(
        _ repository: Repository,
        repositoryID: RepositoryID
    ) async throws -> AsyncThrowingStream<RepositoryNotification, any Error> {
        while true {
            guard let entry = entries[repositoryID] else {
                return try await open(repository, repositoryID: repositoryID)
            }
            switch entry.phase {
            case .open:
                if let stream = entry.channel.makeStream() {
                    return stream
                }
                // The server ended the subscription.
                entries[repositoryID] = nil
            case .opening(let task):
                let succeeded = (try? await task.value) != nil
                finishOpening(entry.channel, succeeded: succeeded)
            case .closing(let task):
                await task.value
                finishClosing(entry.channel)
            }
        }
    }

    /// The channel for a repository, for tests.
    func channel(for repositoryID: RepositoryID) -> NotificationChannel? {
        entries[repositoryID]?.channel
    }

    private func open(
        _ repository: Repository,
        repositoryID: RepositoryID
    ) async throws -> AsyncThrowingStream<RepositoryNotification, any Error> {
        let channel = NotificationChannel(owner: self, repository: repository, repositoryID: repositoryID)
        // The first stream exists before the subscription,
        // so that it receives every notification.
        guard let stream = channel.makeStream() else {
            throw LoreError.missingEvent("a subscription")
        }
        let subscribe = subscribe
        let task = Task { try await subscribe(channel) }
        entries[repositoryID] = Entry(channel: channel, phase: .opening(task))
        do {
            try await task.value
        } catch {
            finishOpening(channel, succeeded: false)
            throw error
        }
        finishOpening(channel, succeeded: true)
        return stream
    }

    /// Moves a channel out of the opening phase,
    /// if no other caller has moved it yet.
    private func finishOpening(_ channel: NotificationChannel, succeeded: Bool) {
        let repositoryID = channel.repositoryID
        guard let entry = entries[repositoryID], entry.channel === channel, case .opening = entry.phase else {
            return
        }
        if succeeded {
            entries[repositoryID]?.phase = .open
        } else {
            entries[repositoryID] = nil
            channel.finishStreams()
        }
    }

    /// Forgets a channel whose library call to unsubscribe has ended,
    /// if no other caller has forgotten it yet.
    private func finishClosing(_ channel: NotificationChannel) {
        let repositoryID = channel.repositoryID
        if let entry = entries[repositoryID], entry.channel === channel, case .closing = entry.phase {
            entries[repositoryID] = nil
        }
    }

    /// Removes a stream that terminated,
    /// and unsubscribes if it was the last stream for the repository.
    func leave(_ channel: NotificationChannel, stream: Int) async {
        let remaining = channel.removeStream(stream)
        let repositoryID = channel.repositoryID
        guard remaining == 0,
            let entry = entries[repositoryID],
            entry.channel === channel,
            case .open = entry.phase
        else {
            return
        }
        if channel.hasEnded {
            entries[repositoryID] = nil
            return
        }
        unsubscribeCount += 1
        let unsubscribe = unsubscribe
        let task = Task { await unsubscribe(channel) }
        entries[repositoryID]?.phase = .closing(task)
        await task.value
        finishClosing(channel)
    }

    /// Forgets a subscription that the library ended.
    func ended(_ channel: NotificationChannel) {
        let repositoryID = channel.repositoryID
        if let entry = entries[repositoryID], entry.channel === channel, case .open = entry.phase {
            entries[repositoryID] = nil
        }
    }
}

/// One library subscription and the streams that share it.
///
/// The library's callback context holds the channel
/// from the call that subscribes until the library ends the subscription.
final class NotificationChannel: Sendable {
    /// The subscriptions that the channel belongs to.
    let owner: NotificationSubscriptions
    let repository: Repository
    let repositoryID: RepositoryID

    private struct State {
        var streams: [Int: AsyncThrowingStream<RepositoryNotification, any Error>.Continuation] = [:]
        var nextStream = 0
        var hasEnded = false
    }

    private let state = Mutex(State())

    init(owner: NotificationSubscriptions, repository: Repository, repositoryID: RepositoryID) {
        self.owner = owner
        self.repository = repository
        self.repositoryID = repositoryID
    }

    /// A Boolean value that indicates whether the library has ended the subscription.
    var hasEnded: Bool {
        state.withLock { $0.hasEnded }
    }

    /// Makes a stream that receives the channel's notifications,
    /// or returns `nil` if the library has ended the subscription.
    func makeStream() -> AsyncThrowingStream<RepositoryNotification, any Error>? {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RepositoryNotification.self)
        let id: Int? = state.withLock { state in
            guard !state.hasEnded else {
                return nil
            }
            let id = state.nextStream
            state.nextStream += 1
            state.streams[id] = continuation
            return id
        }
        guard let id else {
            return nil
        }
        continuation.onTermination = { _ in
            Task { await self.owner.leave(self, stream: id) }
        }
        return stream
    }

    /// Removes a stream and returns the number of streams that remain.
    func removeStream(_ id: Int) -> Int {
        state.withLock { state in
            state.streams[id] = nil
            return state.streams.count
        }
    }

    /// Finishes every stream.
    func finishStreams() {
        let streams = state.withLock { state in
            let streams = state.streams.values
            state.streams = [:]
            return streams
        }
        for stream in streams {
            stream.finish()
        }
    }

    /// Records that the library ended the subscription,
    /// and finishes every stream, throwing the error if there is one.
    func end(_ error: LoreError?) {
        let streams = state.withLock { state in
            state.hasEnded = true
            let streams = state.streams.values
            state.streams = [:]
            return streams
        }
        for stream in streams {
            stream.finish(throwing: error)
        }
        Task { await owner.ended(self) }
    }

    /// Subscribes, returning once the subscription is established.
    func subscribe() async throws {
        let arena = Arena()
        let globals = repository.globals(in: arena)
        let arguments = arena.allocate(lore_notification_subscribe_args_t.self)
        try await subscribe { callback in
            withExtendedLifetime(arena) {
                lore_notification_subscribe_async(globals, arguments, callback)
            }
        }
    }

    /// Subscribes with a function that starts the library call,
    /// which tests replace with one that sends events of their own.
    func subscribe(start: (lore_event_callback_config_t) -> Void) async throws {
        try await Lore.subscribe(
            onEvent: { [self] event in
                guard let notification = RepositoryNotification(event) else {
                    return
                }
                let streams = state.withLock { Array($0.streams.values) }
                for stream in streams {
                    stream.yield(notification)
                }
            },
            onEnd: { [self] error in end(error) },
            start: start
        )
    }

    /// Ends the subscription.
    ///
    /// The library then ends the call that subscribed,
    /// which releases the callback context.
    func unsubscribe() async {
        _ = try? await repository.perform(
            lore_notification_unsubscribe_async,
            transform: { _ -> Never? in nil }
        )
    }
}

extension RepositoryNotification {
    /// Converts a notification event,
    /// returning `nil` for other events and for events without the identifiers they need.
    init?(_ event: UnsafePointer<lore_event_t>) {
        switch event.pointee.tag {
        case LORE_EVENT_NOTIFICATION_BRANCH_CREATED.rawValue:
            guard let branchID = BranchID(event.pointee.notification_branch_created.branch) else {
                return nil
            }
            self = .branchCreated(branchID: branchID)
        case LORE_EVENT_NOTIFICATION_BRANCH_DELETED.rawValue:
            guard let branchID = BranchID(event.pointee.notification_branch_deleted.branch) else {
                return nil
            }
            self = .branchDeleted(branchID: branchID)
        case LORE_EVENT_NOTIFICATION_BRANCH_PUSHED.rawValue:
            let data = event.pointee.notification_branch_pushed
            guard let branchID = BranchID(data.branch), let revision = RevisionID(data.revision) else {
                return nil
            }
            self = .branchPushed(
                branchID: branchID,
                revision: revision,
                revisionNumber: Int(clamping: data.revision_number),
                userID: String(data.user_id)
            )
        case LORE_EVENT_NOTIFICATION_RESOURCE_LOCKED.rawValue:
            let data = event.pointee.notification_resource_locked
            self = .filesLocked(
                paths: [String](data.paths),
                branchID: BranchID(data.branch),
                userID: String(data.user_id)
            )
        case LORE_EVENT_NOTIFICATION_RESOURCE_UNLOCKED.rawValue:
            let data = event.pointee.notification_resource_unlocked
            self = .filesUnlocked(
                paths: [String](data.paths),
                branchID: BranchID(data.branch),
                userID: String(data.user_id)
            )
        default:
            return nil
        }
    }
}
