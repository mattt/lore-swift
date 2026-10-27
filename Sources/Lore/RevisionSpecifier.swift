/// A specifier that names a revision.
///
/// Methods that take a revision accept the forms
/// that the `lore` command-line tool accepts:
/// a whole hash signature,
/// or `branch@number`, `branch@LATEST`, or `branch@hash`,
/// where an omitted branch means the current branch.
/// Create a specifier with a string literal,
/// or with one of the static methods:
///
/// ```swift
/// try await repository.sync(to: "main@2")
/// try await repository.sync(to: .number(2, on: "main"))
/// try await repository.sync(to: .id(revision.id))
/// ```
///
/// A revision identifies its branch,
/// so syncing to a revision on another branch moves onto that branch.
public struct RevisionSpecifier: RawRepresentable, Sendable, Hashable {
    /// The text of the specifier.
    public var rawValue: String

    /// Creates a specifier from its text.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The revision with the given hash signature.
    public static func id(_ id: RevisionID) -> Self {
        Self(rawValue: id.description)
    }

    /// The revision with the given number on a branch.
    ///
    /// - Parameters:
    ///   - number: The number of the revision on the branch.
    ///   - branch: The name of the branch, or `nil` for the current branch.
    public static func number(_ number: Int, on branch: String? = nil) -> Self {
        Self(rawValue: "\(branch ?? "")@\(number)")
    }

    /// The latest revision of a branch.
    ///
    /// - Parameter branch: The name of the branch, or `nil` for the current branch.
    public static func latest(on branch: String? = nil) -> Self {
        Self(rawValue: "\(branch ?? "")@LATEST")
    }
}

extension RevisionSpecifier: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

extension RevisionSpecifier: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}
