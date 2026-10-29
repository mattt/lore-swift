import CLore
import Foundation

/// Memory for the arguments of one call to the C library.
///
/// The library copies its arguments before a call returns,
/// so the arena needs to live only for the duration of the call.
/// Every allocation is zero-filled,
/// padding included,
/// as the header requires of each structure passed to the library.
final class Arena {
    private var allocations: [UnsafeMutableRawPointer] = []

    deinit {
        for allocation in allocations {
            free(allocation)
        }
    }

    /// Allocates a zero-filled value of the given type.
    func allocate<T>(_ type: T.Type = T.self) -> UnsafeMutablePointer<T> {
        allocate(type, count: 1)
    }

    /// Allocates a zero-filled buffer for the given number of values.
    func allocate<T>(_ type: T.Type = T.self, count: Int) -> UnsafeMutablePointer<T> {
        guard let raw = calloc(max(count, 1), MemoryLayout<T>.stride) else {
            fatalError("Lore: out of memory")
        }
        allocations.append(raw)
        return raw.bindMemory(to: T.self, capacity: max(count, 1))
    }

    /// Copies a Swift string into a library string.
    ///
    /// An empty string becomes a null pointer with length 0,
    /// as the library expects.
    func string(_ value: String) -> lore_string_t {
        var value = value
        return value.withUTF8 { bytes in
            guard bytes.count > 0 else {
                return lore_string_t(string: nil, length: 0)
            }
            let buffer = allocate(CChar.self, count: bytes.count + 1)
            UnsafeMutableRawPointer(buffer).copyMemory(
                from: bytes.baseAddress!,
                byteCount: bytes.count
            )
            return lore_string_t(string: buffer, length: UInt(bytes.count))
        }
    }

    /// Copies an optional Swift string into a library string,
    /// using the empty string for `nil`.
    func string(_ value: String?) -> lore_string_t {
        string(value ?? "")
    }

    /// Copies Swift strings into a library string array.
    func strings(_ values: [String]) -> lore_string_array_t {
        guard !values.isEmpty else {
            return lore_string_array_t(ptr: nil, count: 0)
        }
        let buffer = allocate(lore_string_t.self, count: values.count)
        for (index, value) in values.enumerated() {
            buffer[index] = string(value)
        }
        return lore_string_array_t(ptr: buffer, count: UInt(values.count))
    }

    /// Copies bytes into a library byte slice.
    ///
    /// Empty data becomes a null pointer with length 0.
    func bytes(_ data: Data) -> lore_bytes_t {
        guard !data.isEmpty else {
            return lore_bytes_t(ptr: nil, len: 0)
        }
        let buffer = allocate(UInt8.self, count: data.count)
        data.copyBytes(to: buffer, count: data.count)
        return lore_bytes_t(ptr: UnsafeRawPointer(buffer), len: UInt(data.count))
    }

    /// Copies values into a buffer and returns its address and count.
    func array<T>(_ values: [T]) -> (pointer: UnsafePointer<T>?, count: Int) {
        guard !values.isEmpty else {
            return (nil, 0)
        }
        let buffer = allocate(T.self, count: values.count)
        buffer.initialize(from: values, count: values.count)
        return (UnsafePointer(buffer), values.count)
    }
}
