/// An element of the stream that a long-running operation reports.
///
/// Methods such as ``Repository/syncUpdates(to:discardingLocalChanges:)``
/// return a stream of updates:
/// any number of progress reports,
/// then one result.
///
/// ```swift
/// for try await update in repository.syncUpdates() {
///     switch update {
///     case .progress(let progress):
///         print(progress.filesUpdated, "of", progress.filesToUpdate)
///     case .completed(let result):
///         print("Synced to", result.revision)
///     }
/// }
/// ```
public enum OperationUpdate<Progress: Sendable, Result: Sendable>: Sendable {
    /// A report of the progress of the operation.
    case progress(Progress)
    /// The result of the operation,
    /// which is the last element of the stream.
    case completed(Result)
}

extension OperationUpdate: Equatable where Progress: Equatable, Result: Equatable {}
extension OperationUpdate: Hashable where Progress: Hashable, Result: Hashable {}

extension LoreError {
    /// An error for a call that the library reported as successful
    /// without the event that carries its result.
    static func missingEvent(_ description: String) -> LoreError {
        LoreError(
            code: .internal,
            message: "The library reported success without \(description)."
        )
    }
}
