import CLore
import Synchronization

/// Converts a library event into a Swift value,
/// or returns `nil` to skip the event.
///
/// The event and everything it points to is valid
/// only while the function runs,
/// so the function must copy what it keeps.
typealias EventTransform<Event> = @Sendable (UnsafePointer<lore_event_t>) -> Event?

/// Receives the events of one asynchronous call to the C library.
///
/// The library calls `receive(_:)` on one of its worker threads,
/// one event at a time for a given call.
/// Every call ends with a `COMPLETE` event and then an `END` event,
/// including a call that the library rejects before it starts.
private final class EventReceiver: Sendable {
    private let onEvent: @Sendable (UnsafePointer<lore_event_t>) -> Void
    private let onComplete: (@Sendable (LoreError?) -> Void)?
    private let onEnd: @Sendable (LoreError?) -> Void
    private let failure = Mutex<LoreError?>(nil)

    /// Orders the initialization of this receiver
    /// before the library's calls to `receive(_:)`.
    ///
    /// The library hands the receiver to its worker threads
    /// with synchronization that Thread Sanitizer can't see,
    /// because the library isn't instrumented.
    /// This release-acquire pair makes that ordering visible.
    private let published = Atomic<Bool>(false)

    init(
        onEvent: @escaping @Sendable (UnsafePointer<lore_event_t>) -> Void,
        onComplete: (@Sendable (LoreError?) -> Void)? = nil,
        onEnd: @escaping @Sendable (LoreError?) -> Void
    ) {
        self.onEvent = onEvent
        self.onComplete = onComplete
        self.onEnd = onEnd
    }

    /// Handles one event and returns `true` if it ends the call.
    func receive(_ event: UnsafePointer<lore_event_t>) -> Bool {
        _ = published.load(ordering: .acquiring)
        switch event.pointee.tag {
        case LORE_EVENT_COMPLETE.rawValue:
            let complete = event.pointee.complete
            var error: LoreError?
            if complete.status != 0 {
                error = LoreError(status: complete.status, detail: complete.error)
                failure.withLock { $0 = error }
            }
            onComplete?(error)
            return false
        case LORE_EVENT_END.rawValue:
            onEnd(failure.withLock { $0 })
            return true
        case LORE_EVENT_LOG.rawValue:
            LogHandler.dispatch(event.pointee.log)
            return false
        default:
            onEvent(event)
            return false
        }
    }

    /// Makes a callback configuration that delivers events to this receiver.
    ///
    /// The configuration holds a strong reference to the receiver,
    /// which the callback releases when the call ends.
    /// Pass the configuration to exactly one call.
    func retainedCallbackConfiguration() -> lore_event_callback_config_t {
        published.store(true, ordering: .releasing)
        let context = Unmanaged.passRetained(self).toOpaque()
        return lore_event_callback_config_t(
            user_context: UInt64(UInt(bitPattern: context)),
            func: { event, userContext in
                guard
                    let event,
                    let context = UnsafeRawPointer(bitPattern: UInt(userContext))
                else {
                    return
                }
                let receiver = Unmanaged<EventReceiver>.fromOpaque(context)
                if receiver.takeUnretainedValue().receive(event) {
                    receiver.release()
                }
            }
        )
    }
}

/// Collects the events of a call.
private final class Accumulator<Event: Sendable>: Sendable {
    private let storage = Mutex<[Event]>([])

    var values: [Event] {
        storage.withLock { $0 }
    }

    func append(_ value: Event) {
        storage.withLock { $0.append(value) }
    }
}

/// Starts an asynchronous call to the C library
/// and waits for it to end,
/// returning the events that `transform` converts.
///
/// The library offers no way to cancel a call,
/// so this function waits for the call to end
/// even if the current task is cancelled.
///
/// - Parameters:
///   - transform: Converts each event that the call reports.
///   - start: Calls a `lore_*_async` function with the given callback configuration.
///     The function must call it exactly once, synchronously.
/// - Throws: ``LoreError`` if the call fails.
func perform<Event: Sendable>(
    _ transform: @escaping EventTransform<Event>,
    start: (lore_event_callback_config_t) -> Void
) async throws -> [Event] {
    let events = Accumulator<Event>()
    return try await withCheckedThrowingContinuation { continuation in
        let receiver = EventReceiver(
            onEvent: { event in
                if let value = transform(event) {
                    events.append(value)
                }
            },
            onEnd: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: events.values)
                }
            }
        )
        start(receiver.retainedCallbackConfiguration())
    }
}

/// Starts an asynchronous call to the C library without waiting for it.
///
/// The callback context stays alive until the library ends the call,
/// so the caller can return,
/// or its object can be deinitialized,
/// while the call runs.
///
/// - Parameters:
///   - onEnd: Runs once, on one of the library's worker threads,
///     when the library ends the call,
///     with the error if the call failed.
///   - start: Calls a `lore_*_async` function with the given callback configuration.
///     The function must call it exactly once, synchronously.
func detach(
    onEnd: @escaping @Sendable (LoreError?) -> Void,
    start: (lore_event_callback_config_t) -> Void
) {
    let receiver = EventReceiver(onEvent: { _ in }, onEnd: onEnd)
    start(receiver.retainedCallbackConfiguration())
}

/// Starts an asynchronous call to the C library
/// and returns a stream of its progress and its result.
///
/// The stream yields a ``OperationUpdate/progress(_:)`` element
/// for each event that `progress` converts,
/// then one ``OperationUpdate/completed(_:)`` element
/// with the value that `result` computes from all of the events,
/// and then finishes.
/// The stream throws ``LoreError`` if the call fails.
/// Cancelling the task that iterates the stream ends the iteration,
/// but the call keeps running until the library ends it.
///
/// - Parameters:
///   - transform: Converts each event that the call reports.
///   - progress: Selects the converted events to yield as progress.
///   - result: Computes the result of the call from its converted events.
///   - start: Calls a `lore_*_async` function with the given callback configuration.
///     The function must call it exactly once, synchronously.
func stream<Event: Sendable, Progress: Sendable, Result: Sendable>(
    _ transform: @escaping EventTransform<Event>,
    progress: @escaping @Sendable (Event) -> Progress?,
    result: @escaping @Sendable ([Event]) throws -> Result,
    start: (lore_event_callback_config_t) -> Void
) -> AsyncThrowingStream<OperationUpdate<Progress, Result>, any Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(
        of: OperationUpdate<Progress, Result>.self
    )
    let events = Accumulator<Event>()
    let receiver = EventReceiver(
        onEvent: { event in
            guard let value = transform(event) else {
                return
            }
            events.append(value)
            if let update = progress(value) {
                continuation.yield(.progress(update))
            }
        },
        onEnd: { error in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            do {
                continuation.yield(.completed(try result(events.values)))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    )
    start(receiver.retainedCallbackConfiguration())
    return stream
}

/// Starts an asynchronous call to the C library that keeps reporting events
/// after it completes,
/// and waits for it to complete.
///
/// A notification subscription completes once it's established,
/// and then reports events until the subscription ends,
/// when the library sends its `END` event.
/// The callback context stays alive until then.
///
/// - Parameters:
///   - onEvent: Receives each event other than the standard ones,
///     on one of the library's worker threads.
///     The event is valid only while the function runs.
///   - onEnd: Runs once, when the library ends the call.
///   - start: Calls a `lore_*_async` function with the given callback configuration.
///     The function must call it exactly once, synchronously.
/// - Throws: ``LoreError`` if the call fails.
func subscribe(
    onEvent: @escaping @Sendable (UnsafePointer<lore_event_t>) -> Void,
    onEnd: @escaping @Sendable () -> Void,
    start: (lore_event_callback_config_t) -> Void
) async throws {
    // The library sends `COMPLETE` before `END`;
    // the continuation is resumed by whichever arrives first.
    let pending = Mutex<CheckedContinuation<Void, any Error>?>(nil)
    @Sendable func resume(_ error: LoreError?) {
        guard let continuation = pending.withLock({ $0.take() }) else {
            return
        }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
    try await withCheckedThrowingContinuation { continuation in
        pending.withLock { $0 = continuation }
        let receiver = EventReceiver(
            onEvent: onEvent,
            onComplete: resume,
            onEnd: { error in
                resume(error ?? LoreError.missingEvent("a completion"))
                onEnd()
            }
        )
        start(receiver.retainedCallbackConfiguration())
    }
}
