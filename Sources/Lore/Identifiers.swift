import CLore

/// The hash signature that identifies a revision.
///
/// A revision ID is a 256-bit hash.
/// Its ``description`` is 64 lowercase hexadecimal digits,
/// which you can pass anywhere the library accepts a revision.
public struct RevisionID: Sendable, Hashable {
    /// The 32 bytes of the hash.
    public let bytes: [UInt8]

    /// Creates a revision ID from the 32 bytes of its hash.
    ///
    /// Returns `nil` if `bytes` doesn't hold exactly 32 bytes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 32 else {
            return nil
        }
        self.bytes = bytes
    }

    /// Creates a revision ID from 64 hexadecimal digits.
    public init?(_ description: some StringProtocol) {
        guard let bytes = decodeHexadecimal(description) else {
            return nil
        }
        self.init(bytes: bytes)
    }

    /// Copies a library hash,
    /// returning `nil` for the all-zero hash
    /// that the library uses to mean "none".
    init?(_ hash: lore_hash_t) {
        let bytes = tupleBytes(hash.data)
        guard bytes.contains(where: { $0 != 0 }) else {
            return nil
        }
        self.bytes = bytes
    }
}

extension RevisionID: CustomStringConvertible {
    public var description: String {
        hexadecimal(bytes)
    }
}

/// The 128-bit identifier of a branch.
public struct BranchID: Sendable, Hashable {
    /// The 16 bytes of the identifier.
    public let bytes: [UInt8]

    /// Creates a branch ID from its 16 bytes.
    ///
    /// Returns `nil` if `bytes` doesn't hold exactly 16 bytes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else {
            return nil
        }
        self.bytes = bytes
    }

    /// Copies a library context,
    /// returning `nil` for the all-zero value.
    init?(_ context: lore_context_t) {
        let bytes = tupleBytes(context.data)
        guard bytes.contains(where: { $0 != 0 }) else {
            return nil
        }
        self.bytes = bytes
    }
}

extension BranchID: CustomStringConvertible {
    public var description: String {
        hexadecimal(bytes)
    }
}

/// The 128-bit identifier of a repository.
public struct RepositoryID: Sendable, Hashable {
    /// The 16 bytes of the identifier.
    public let bytes: [UInt8]

    /// Creates a repository ID from its 16 bytes.
    ///
    /// Returns `nil` if `bytes` doesn't hold exactly 16 bytes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else {
            return nil
        }
        self.bytes = bytes
    }

    /// Copies a library partition,
    /// returning `nil` for the all-zero value.
    init?(_ partition: lore_partition_t) {
        let bytes = tupleBytes(partition.data)
        guard bytes.contains(where: { $0 != 0 }) else {
            return nil
        }
        self.bytes = bytes
    }
}

extension RepositoryID: CustomStringConvertible {
    public var description: String {
        hexadecimal(bytes)
    }
}
