import CLore
import Synchronization

/// A change on the server that a notification subscription reports.
public enum RepositoryNotification: Sendable, Hashable {
    /// A branch was created.
    case branchCreated(branchID: BranchID)

    /// A branch was archived or deleted.
    case branchDeleted(branchID: BranchID)

    /// A push made a revision the latest revision of a branch.
    ///
    /// - Parameters:
    ///   - branchID: The branch.
    ///   - revisionID: The new latest revision of the branch.
    ///   - revisionNumber: The number of the revision on the branch.
    ///   - userID: The identifier of the user who pushed,
    ///     or `<unknown>` for a server that doesn't authenticate its users.
    case branchPushed(branchID: BranchID, revisionID: RevisionID, revisionNumber: Int, userID: String)

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
    /// for await notification in try await repository.notifications() {
    ///     if case .branchPushed(_, let revisionID, _, let userID) = notification {
    ///         print(userID, "pushed", revisionID)
    ///     }
    /// }
    /// ```
    ///
    /// The subscription lasts until the stream terminates:
    /// when the task that iterates it is cancelled,
    /// when the stream and its iterator are released,
    /// or when the server ends the subscription,
    /// which finishes the stream.
    /// The library keeps one subscription for each repository in a process,
    /// so every stream for the repository,
    /// including the streams of its clones in the same process,
    /// shares it,
    /// and the binding ends it when the last of them terminates.
    ///
    /// - Returns: A stream of notifications.
    /// - Throws: ``LoreError`` if the library can't subscribe.
    ///   Lore 0.11.0 reports an offline repository with ``LoreError/Code/internal``.
    public func notifications() async throws -> AsyncStream<RepositoryNotification> {
        let repositoryID = try await state().repositoryID
        return try await NotificationSubscriptions.shared.join(self, repositoryID: repositoryID)
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

    /// The number of times the actor has asked the library to unsubscribe,
    /// for tests.
    private(set) var unsubscribeCount = 0

    /// Returns a stream of the notifications for a repository,
    /// subscribing first if no stream for the repository is active.
    func join(_ repository: Repository, repositoryID: RepositoryID) async throws -> AsyncStream<RepositoryNotification>
    {
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
                _ = try? await task.value
            case .closing(let task):
                await task.value
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
    ) async throws -> AsyncStream<RepositoryNotification> {
        let channel = NotificationChannel(repository: repository, repositoryID: repositoryID)
        // The first stream exists before the subscription,
        // so that it receives every notification.
        guard let stream = channel.makeStream() else {
            throw LoreError.missingEvent("a subscription")
        }
        let task = Task { try await channel.subscribe() }
        entries[repositoryID] = Entry(channel: channel, phase: .opening(task))
        do {
            try await task.value
        } catch {
            entries[repositoryID] = nil
            channel.finishStreams()
            throw error
        }
        entries[repositoryID]?.phase = .open
        return stream
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
        let task = Task { await channel.unsubscribe() }
        entries[repositoryID]?.phase = .closing(task)
        await task.value
        if entries[repositoryID]?.channel === channel {
            entries[repositoryID] = nil
        }
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
    let repository: Repository
    let repositoryID: RepositoryID

    private struct State {
        var streams: [Int: AsyncStream<RepositoryNotification>.Continuation] = [:]
        var nextStream = 0
        var hasEnded = false
    }

    private let state = Mutex(State())

    init(repository: Repository, repositoryID: RepositoryID) {
        self.repository = repository
        self.repositoryID = repositoryID
    }

    /// A Boolean value that indicates whether the library has ended the subscription.
    var hasEnded: Bool {
        state.withLock { $0.hasEnded }
    }

    /// Makes a stream that receives the channel's notifications,
    /// or returns `nil` if the library has ended the subscription.
    func makeStream() -> AsyncStream<RepositoryNotification>? {
        let (stream, continuation) = AsyncStream.makeStream(of: RepositoryNotification.self)
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
            Task { await NotificationSubscriptions.shared.leave(self, stream: id) }
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

    /// Subscribes, returning once the subscription is established.
    func subscribe() async throws {
        let arena = Arena()
        let globals = repository.globals(in: arena)
        let arguments = arena.allocate(lore_notification_subscribe_args_t.self)
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
            onEnd: { [self] in
                let streams = state.withLock { state in
                    state.hasEnded = true
                    let streams = state.streams.values
                    state.streams = [:]
                    return streams
                }
                for stream in streams {
                    stream.finish()
                }
                Task { await NotificationSubscriptions.shared.ended(self) }
            },
            start: { callback in
                withExtendedLifetime(arena) {
                    lore_notification_subscribe_async(globals, arguments, callback)
                }
            }
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
            guard let branchID = BranchID(data.branch), let revisionID = RevisionID(data.revision) else {
                return nil
            }
            self = .branchPushed(
                branchID: branchID,
                revisionID: revisionID,
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
