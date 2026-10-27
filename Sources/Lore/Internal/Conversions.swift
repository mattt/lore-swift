import CLore

extension String {
    /// Copies a library string.
    ///
    /// The library may pass bytes that are not valid UTF-8;
    /// the copy replaces them with U+FFFD.
    init(_ value: lore_string_t) {
        guard let pointer = value.string, value.length > 0 else {
            self = ""
            return
        }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(value.length))
        self = String(decoding: bytes, as: UTF8.self)
    }
}

extension Array where Element == String {
    /// Copies a library string array.
    init(_ value: lore_string_array_t) {
        guard let pointer = value.ptr, value.count > 0 else {
            self = []
            return
        }
        self = UnsafeBufferPointer(start: pointer, count: Int(value.count)).map(String.init)
    }
}

extension Bool {
    /// Converts a library flag, where any non-zero value is true.
    init(_ flag: UInt8) {
        self = flag != 0
    }
}

extension UInt8 {
    /// Converts a Boolean value to a library flag.
    init(_ flag: Bool) {
        self = flag ? 1 : 0
    }
}

/// Copies the bytes of a fixed-size C array,
/// which Swift imports as a tuple.
func tupleBytes<T>(_ tuple: T) -> [UInt8] {
    withUnsafeBytes(of: tuple) { Array($0) }
}

/// Formats bytes as lowercase hexadecimal digits.
func hexadecimal(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var result: [UInt8] = []
    result.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        result.append(digits[Int(byte >> 4)])
        result.append(digits[Int(byte & 0x0f)])
    }
    return String(decoding: result, as: UTF8.self)
}

/// Parses lowercase or uppercase hexadecimal digits into bytes.
func decodeHexadecimal(_ string: some StringProtocol) -> [UInt8]? {
    let utf8 = Array(string.utf8)
    guard utf8.count.isMultiple(of: 2) else {
        return nil
    }
    func value(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
    var result: [UInt8] = []
    result.reserveCapacity(utf8.count / 2)
    var index = 0
    while index < utf8.count {
        guard let high = value(utf8[index]), let low = value(utf8[index + 1]) else {
            return nil
        }
        result.append(high << 4 | low)
        index += 2
    }
    return result
}
