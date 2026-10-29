import CLore

/// The hash signature that identifies a revision.
///
/// A revision ID is a 256-bit hash.
/// Its ``description`` is 64 lowercase hexadecimal digits.
/// Pass ``RevisionSpecifier/id(_:)`` to name the revision
/// in methods that take a revision.
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
    ///
    /// Returns `nil` if `description` isn't 64 hexadecimal digits.
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

extension RevisionID: LosslessStringConvertible {
    public var description: String {
        hexadecimal(bytes)
    }
}

/// The 128-bit identifier of a branch.
///
/// Its ``description`` is 32 lowercase hexadecimal digits.
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

    /// Creates a branch ID from 32 hexadecimal digits.
    ///
    /// Returns `nil` if `description` isn't 32 hexadecimal digits.
    public init?(_ description: some StringProtocol) {
        guard let bytes = decodeHexadecimal(description) else {
            return nil
        }
        self.init(bytes: bytes)
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

extension BranchID: LosslessStringConvertible {
    public var description: String {
        hexadecimal(bytes)
    }
}

/// The 128-bit identifier of a repository.
///
/// Its ``description`` is 32 lowercase hexadecimal digits.
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

    /// Creates a repository ID from 32 hexadecimal digits.
    ///
    /// Returns `nil` if `description` isn't 32 hexadecimal digits.
    public init?(_ description: some StringProtocol) {
        guard let bytes = decodeHexadecimal(description) else {
            return nil
        }
        self.init(bytes: bytes)
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

extension RepositoryID: LosslessStringConvertible {
    public var description: String {
        hexadecimal(bytes)
    }
}

/// The address of content in a repository's store:
/// a 256-bit hash of the content and a 128-bit context.
///
/// Its ``description`` is the hash and the context
/// as lowercase hexadecimal digits,
/// separated by a hyphen.
public struct ContentAddress: Sendable, Hashable {
    /// The 32 bytes of the content hash.
    public let hash: [UInt8]

    /// The 16 bytes of the context.
    public let context: [UInt8]

    /// Creates an address from a 32-byte hash and a 16-byte context.
    ///
    /// Returns `nil` if `hash` doesn't hold exactly 32 bytes
    /// or `context` doesn't hold exactly 16 bytes.
    public init?(hash: [UInt8], context: [UInt8]) {
        guard hash.count == 32, context.count == 16 else {
            return nil
        }
        self.hash = hash
        self.context = context
    }

    /// Creates an address from 64 hexadecimal digits for the hash,
    /// a hyphen,
    /// and 32 hexadecimal digits for the context.
    ///
    /// Returns `nil` if `description` doesn't have that form.
    public init?(_ description: some StringProtocol) {
        let parts = description.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let hash = decodeHexadecimal(parts[0]),
            let context = decodeHexadecimal(parts[1])
        else {
            return nil
        }
        self.init(hash: hash, context: context)
    }

    /// Copies a library address.
    init(_ address: lore_address_t) {
        self.hash = tupleBytes(address.hash.data)
        self.context = tupleBytes(address.context.data)
    }
}

extension ContentAddress: LosslessStringConvertible {
    public var description: String {
        "\(hexadecimal(hash))-\(hexadecimal(context))"
    }
}
