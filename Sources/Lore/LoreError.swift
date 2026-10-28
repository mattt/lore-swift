import CLore
import Foundation

/// An error that the Lore library reports for a failed operation.
///
/// Every operation ends with a completion event
/// that carries a status code and,
/// on failure,
/// a message and a trace of source locations inside the library.
/// The binding throws that detail as a `LoreError`.
///
/// Match on ``code`` to handle a specific failure:
///
/// ```swift
/// do {
///     try await repository.commit(message: "Update")
/// } catch let error as LoreError where error.code == .nothingStaged {
///     print("Nothing to commit")
/// }
/// ```
public struct LoreError: Error, Sendable, Hashable {
    /// The error code.
    public var code: Code

    /// The error message from the library.
    public var message: String

    /// The source locations the library recorded for the error,
    /// innermost first.
    ///
    /// Release builds of the library may record no locations.
    public var trace: [TraceLocation]

    /// Creates an error with the given code, message, and trace.
    public init(code: Code, message: String = "", trace: [TraceLocation] = []) {
        self.code = code
        self.message = message
        self.trace = trace
    }
}

extension LoreError {
    /// A numeric error code from the Lore error registry.
    ///
    /// The library groups codes into ranges by kind of failure,
    /// such as 3–15 for invalid input and 79–99 for missing resources;
    /// ``category`` reports the range of a code.
    /// The named codes come from `lore-base/src/error.rs`
    /// in Lore 0.11.0;
    /// the C header names only a few of them.
    public struct Code: RawRepresentable, Sendable, Hashable {
        /// The raw value of the code.
        public var rawValue: Int32

        /// Creates a code from its raw value.
        public init(rawValue: Int32) {
            self.rawValue = rawValue
        }
    }

    /// A range of error codes that share a kind of failure.
    public enum Category: Sendable, Hashable {
        /// The arguments were malformed or named the wrong kind of thing.
        case invalidInput
        /// The caller is not authenticated or not authorized.
        case authentication
        /// A remote or the local service could not be reached.
        case connectivity
        /// The repository is in a state that refuses the operation.
        case repositoryState
        /// The operation would create something that already exists.
        case alreadyExists
        /// A named resource does not exist.
        case notFound
        /// Something the operation needs was not configured.
        case configuration
        /// A size, depth, or efficiency limit was reached.
        case resourceLimit
        /// The library cannot serve the call.
        case lifecycle
        /// An internal error or a code outside the known ranges.
        case other
    }
}

extension LoreError.Code {
    /// The category of the code,
    /// from the ranges of the Lore error registry.
    public var category: LoreError.Category {
        switch rawValue {
        case 3 ... 15: .invalidInput
        case 16 ... 27: .authentication
        case 28 ... 39: .connectivity
        case 40 ... 55: .repositoryState
        case 56 ... 63: .alreadyExists
        case 79 ... 99: .notFound
        case 110 ... 117: .configuration
        case 118 ... 125: .resourceLimit
        case 193 ... 200: .lifecycle
        default: .other
        }
    }

    /// An internal error in the library.
    public static let `internal` = Self(rawValue: -1)
    /// The arguments to the operation were invalid.
    public static let invalidArguments = Self(rawValue: 3)
    /// A path was invalid.
    public static let invalidPath = Self(rawValue: 4)
    /// A path doesn't name a link.
    public static let notALink = Self(rawValue: 6)
    /// The operation is not supported.
    public static let notSupported = Self(rawValue: 9)
    /// The caller is not authenticated.
    public static let notAuthenticated = Self(rawValue: 16)
    /// The caller is not authorized to access the repository.
    public static let notAuthorized = Self(rawValue: 17)
    /// The connection to the server was lost.
    public static let disconnected = Self(rawValue: 28)
    /// The remote could not be reached.
    public static let notConnected = Self(rawValue: 29)
    /// The server is in maintenance mode.
    public static let maintenance = Self(rawValue: 30)
    /// The store is overloaded; retry later.
    public static let slowDown = Self(rawValue: 31)
    /// Nothing is staged for commit.
    public static let nothingStaged = Self(rawValue: 40)
    /// Another instance advanced the branch; sync and stage again.
    public static let branchAdvanced = Self(rawValue: 41)
    /// The branch history is divergent.
    public static let divergent = Self(rawValue: 42)
    /// A file is still in conflict.
    public static let conflict = Self(rawValue: 43)
    /// Local modifications prevent the operation.
    public static let localModifications = Self(rawValue: 44)
    /// Somebody else holds the lock.
    public static let lockNotOwned = Self(rawValue: 45)
    /// The new metadata is identical to the original.
    public static let identicalMetadata = Self(rawValue: 46)
    /// The repository is already a layer at the path.
    public static let alreadyLinked = Self(rawValue: 56)
    /// The branch already exists.
    public static let branchAlreadyExists = Self(rawValue: 57)
    /// A repository already exists at the path.
    public static let repositoryAlreadyExists = Self(rawValue: 58)
    /// A resource was not found.
    public static let notFound = Self(rawValue: 79)
    /// A file was not found.
    public static let fileNotFound = Self(rawValue: 82)
    /// No file, directory, or link exists at a path.
    public static let nodeNotFound = Self(rawValue: 83)
    /// No layer exists at a path.
    public static let layerNotFound = Self(rawValue: 86)
    /// A branch was not found.
    public static let branchNotFound = Self(rawValue: 87)
    /// A revision was not found.
    public static let revisionNotFound = Self(rawValue: 88)
    /// A repository was not found.
    public static let repositoryNotFound = Self(rawValue: 89)
    /// A lock does not exist.
    public static let lockNotFound = Self(rawValue: 91)
    /// No identity is configured for the commit.
    public static let missingIdentity = Self(rawValue: 110)
    /// No remote is configured.
    public static let noRemote = Self(rawValue: 111)
    /// The library has been shut down.
    public static let shutDown = Self(rawValue: 193)
}

extension LoreError.Code: CustomStringConvertible {
    public var description: String {
        String(rawValue)
    }
}

extension LoreError {
    /// A source location inside the library that an error passed through.
    public struct TraceLocation: Sendable, Hashable {
        /// The source file path.
        public var file: String
        /// The line number.
        public var line: Int
        /// The column number.
        public var column: Int
        /// A description of the operation at the location,
        /// or an empty string.
        public var context: String

        /// Creates a trace location.
        public init(file: String, line: Int, column: Int, context: String = "") {
            self.file = file
            self.line = line
            self.column = column
            self.context = context
        }
    }
}

extension LoreError: CustomStringConvertible {
    /// A description in the format of the Go SDK's `LoreError`,
    /// with one line for each trace location.
    public var description: String {
        var result =
            message.isEmpty
            ? "Lore operation failed with code \(code)"
            : "Lore error \(code): \(message)"
        for location in trace {
            result += "\n    at \(location.file):\(location.line):\(location.column)"
            if !location.context.isEmpty {
                result += " (\(location.context))"
            }
        }
        return result
    }
}

extension LoreError: LocalizedError {
    /// The message from the library,
    /// or a description of the code if the message is empty.
    public var errorDescription: String? {
        message.isEmpty ? "Lore operation failed with code \(code)" : message
    }
}

extension LoreError {
    /// Copies the error detail of a completion event.
    init(status: Int32, detail: lore_error_detail_t) {
        let code = detail.error_code != 0 ? detail.error_code : status
        let locations = UnsafeBufferPointer(
            start: detail.trace_locations.ptr,
            count: detail.trace_locations.ptr == nil ? 0 : Int(detail.trace_locations.count)
        )
        self.init(
            code: Code(rawValue: code),
            message: String(detail.message),
            trace: locations.map { location in
                TraceLocation(
                    file: String(location.file),
                    line: Int(location.line),
                    column: Int(location.column),
                    context: String(location.context)
                )
            }
        )
    }
}
