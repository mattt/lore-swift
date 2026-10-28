import CLore

/// A typed value stored as metadata of a file, revision, branch, or repository.
///
/// Corresponds to `lore_metadata_t` and `lore_metadata_type_t`.
public enum MetadataValue: Sendable, Hashable {
    /// Text.
    case string(String)
    /// An unsigned 64-bit integer.
    case number(UInt64)
    /// A Boolean value.
    case boolean(Bool)
    /// Raw bytes of any length.
    ///
    /// The methods that set metadata can't set a binary value:
    /// in Lore 0.11.0,
    /// `lore_file_metadata_set` reads the text of a binary value
    /// as the path of a file,
    /// stores the file's content,
    /// and records its ``address(hash:context:)``.
    case binary([UInt8])
    /// A 32-byte content hash.
    case hash([UInt8])
    /// A 16-byte context identifier.
    case context([UInt8])
    /// A content address: a 32-byte hash and a 16-byte context.
    case address(hash: [UInt8], context: [UInt8])
}

extension MetadataValue {
    /// Copies a library metadata value.
    init?(_ value: lore_metadata_t) {
        switch value.tag {
        case LORE_METADATA_TYPE_STRING.rawValue:
            self = .string(String(value.string))
        case LORE_METADATA_TYPE_NUMERIC.rawValue:
            self = .number(value.numeric)
        case LORE_METADATA_TYPE_BOOLEAN.rawValue:
            self = .boolean(Bool(value.boolean))
        case LORE_METADATA_TYPE_BINARY.rawValue:
            let binary = value.binary
            if let payload = binary.payload, binary.length > 0 {
                self = .binary(Array(UnsafeRawBufferPointer(start: payload, count: Int(binary.length))))
            } else {
                self = .binary([])
            }
        case LORE_METADATA_TYPE_HASH.rawValue:
            self = .hash(tupleBytes(value.hash.data))
        case LORE_METADATA_TYPE_CONTEXT.rawValue:
            self = .context(tupleBytes(value.context.data))
        case LORE_METADATA_TYPE_ADDRESS.rawValue:
            self = .address(
                hash: tupleBytes(value.address.hash.data),
                context: tupleBytes(value.address.context.data)
            )
        default:
            return nil
        }
    }

    /// The type and text that the library's metadata set functions take for the value,
    /// or `nil` if the binding can't express the value as text.
    var encoded: (type: lore_metadata_type_t, text: String)? {
        switch self {
        case .string(let string):
            (LORE_METADATA_TYPE_STRING, string)
        case .number(let number):
            (LORE_METADATA_TYPE_NUMERIC, String(number))
        case .boolean(let boolean):
            (LORE_METADATA_TYPE_BOOLEAN, boolean ? "true" : "false")
        case .binary:
            nil
        case .hash(let bytes):
            (LORE_METADATA_TYPE_HASH, hexadecimal(bytes))
        case .context(let bytes):
            (LORE_METADATA_TYPE_CONTEXT, hexadecimal(bytes))
        case .address:
            nil
        }
    }
}

/// Metadata values as the parallel arrays of keys, texts, and types
/// that the library's metadata set functions take.
struct EncodedMetadata {
    var keys: [String] = []
    var texts: [String] = []
    var types: [lore_metadata_type_t] = []

    /// Encodes values in the order of their keys.
    ///
    /// - Throws: ``LoreError`` with ``LoreError/Code/notSupported``
    ///   for a value that the binding can't express as text.
    init(_ values: [String: MetadataValue]) throws {
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            guard let encoded = value.encoded else {
                throw LoreError(
                    code: .notSupported,
                    message: "The binding can't set the metadata value for \(key)."
                )
            }
            keys.append(key)
            texts.append(encoded.text)
            types.append(encoded.type)
        }
    }

    /// Copies the types into a library array.
    func formats(in arena: Arena) -> lore_metadata_type_array_t {
        let formats = arena.array(types)
        return lore_metadata_type_array_t(ptr: formats.pointer, count: UInt(formats.count))
    }
}

/// A key and value that a `LORE_EVENT_METADATA` event reports.
struct MetadataEntry: Sendable {
    var key: String
    var value: MetadataValue

    init?(_ event: UnsafePointer<lore_event_t>) {
        guard event.pointee.tag == LORE_EVENT_METADATA.rawValue,
            let value = MetadataValue(event.pointee.metadata.value)
        else {
            return nil
        }
        self.key = String(event.pointee.metadata.key)
        self.value = value
    }
}

extension Dictionary where Key == String, Value == MetadataValue {
    /// Collects metadata entries, keeping the last value for a repeated key.
    init(_ entries: some Sequence<MetadataEntry>) {
        self.init(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
    }
}

extension Repository {
    /// Performs an operation that reports metadata
    /// and returns the entries it reports.
    func metadataEntries<Arguments>(
        _ function: (
            UnsafePointer<lore_global_args_t>?,
            UnsafePointer<Arguments>?,
            lore_event_callback_config_t
        ) -> Void,
        configure: (UnsafeMutablePointer<Arguments>, Arena) -> Void
    ) async throws -> [String: MetadataValue] {
        Dictionary(try await perform(function, configure: configure, transform: MetadataEntry.init))
    }
}

extension Repository {
    /// Returns the metadata value of a file for a key.
    ///
    /// - Parameters:
    ///   - key: The metadata key.
    ///   - path: The path of the file, relative to the repository directory.
    ///   - revision: The revision to read,
    ///     or `nil` for the current state of the working directory.
    /// - Returns: The value, or `nil` if the file has no value for the key.
    /// - Throws: ``LoreError`` if the library can't read the metadata.
    public func metadata(
        forKey key: String,
        of path: String,
        revision: RevisionSpecifier? = nil
    ) async throws -> MetadataValue? {
        let values = try await metadataEntries(
            lore_file_metadata_get_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_metadata_get_args_t>, arena) in
                arguments.pointee.key = arena.string(key)
                arguments.pointee.path = arena.string(path)
                arguments.pointee.revision = arena.string(revision?.rawValue)
            }
        )
        return values[key]
    }

    /// Returns the metadata of a file.
    ///
    /// - Parameters:
    ///   - path: The path of the file, relative to the repository directory.
    ///   - revision: The revision to read,
    ///     or `nil` for the current state of the working directory.
    /// - Returns: The metadata values, by key.
    /// - Throws: ``LoreError`` if the library can't read the metadata.
    public func metadata(
        of path: String,
        revision: RevisionSpecifier? = nil
    ) async throws -> [String: MetadataValue] {
        try await metadataEntries(
            lore_file_metadata_list_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_metadata_list_args_t>, arena) in
                arguments.pointee.path = arena.string(path)
                arguments.pointee.revision = arena.string(revision?.rawValue)
            }
        )
    }

    /// Sets metadata values on files.
    ///
    /// The values become part of the files' staged state.
    ///
    /// - Parameters:
    ///   - values: The values to set, by key.
    ///   - paths: The paths of the files, relative to the repository directory.
    /// - Throws: ``LoreError`` if the library can't set the metadata,
    ///   or with ``LoreError/Code/notSupported``
    ///   for a ``MetadataValue/binary(_:)``
    ///   or ``MetadataValue/address(hash:context:)`` value,
    ///   which the binding can't set.
    public func setMetadata(_ values: [String: MetadataValue], of paths: [String]) async throws {
        let metadata = try EncodedMetadata(values)
        // The library reads the keys, values, and types as flat arrays,
        // taking the number of entries for each path from `entries`.
        let count = UInt32(metadata.keys.count)
        _ = try await perform(
            lore_file_metadata_set_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_metadata_set_args_t>, arena) in
                arguments.pointee.paths = arena.strings(paths)
                arguments.pointee.keys = arena.strings(paths.flatMap { _ in metadata.keys })
                arguments.pointee.values = arena.strings(paths.flatMap { _ in metadata.texts })
                let formats = arena.array(paths.flatMap { _ in metadata.types })
                arguments.pointee.formats = lore_metadata_type_array_t(
                    ptr: formats.pointer,
                    count: UInt(formats.count)
                )
                let counts = arena.array(paths.map { _ in count })
                arguments.pointee.entries = lore_uint32_array_t(
                    ptr: counts.pointer,
                    count: UInt(counts.count)
                )
            },
            transform: { _ -> Never? in nil }
        )
    }

    /// Removes every metadata value from a file.
    ///
    /// The removal becomes part of the file's staged state.
    ///
    /// - Parameter path: The path of the file, relative to the repository directory.
    /// - Throws: ``LoreError`` if the library can't clear the metadata.
    public func clearMetadata(of path: String) async throws {
        _ = try await perform(
            lore_file_metadata_clear_async,
            configure: { (arguments: UnsafeMutablePointer<lore_file_metadata_clear_args_t>, arena) in
                arguments.pointee.path = arena.string(path)
            },
            transform: { _ -> Never? in nil }
        )
    }
}
