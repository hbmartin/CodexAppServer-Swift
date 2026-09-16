import Foundation

/// A lossless, forward-compatible JSON value used at the protocol boundary.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(Decimal.self) { self = .number(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([JSONValue].self) { self = .array(item) }
        else if let item = try? value.decode([String: JSONValue].self) { self = .object(item) }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }
}

public extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }
    subscript(_ index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var decimalValue: Decimal? { if case .number(let value) = self { value } else { nil } }
    /// Returns an integer only when the JSON number is integral and exactly representable by `Int`.
    var intValue: Int? {
        guard let value = int64Value else { return nil }
        return Int(exactly: value)
    }
    /// Returns an integer only when the JSON number is integral and exactly representable by `Int64`.
    var int64Value: Int64? {
        guard let decimal = decimalValue else { return nil }
        let value = NSDecimalNumber(decimal: decimal).int64Value
        guard Decimal(value) == decimal else { return nil }
        return value
    }
    var uint32Value: UInt32? {
        guard let value = int64Value else { return nil }
        return UInt32(exactly: value)
    }
    /// The first non-empty string among `keys`, tried in order.
    ///
    /// Identity fields are read through this accessor so that an absent key, a null, a
    /// wrong-typed value, and an empty string all fail the same way instead of silently
    /// producing `""`. `context` names the enclosing model for the error message.
    ///
    /// - Throws: `CodexError.missingField` naming `context` and the candidate keys.
    func requireString(_ keys: String..., context: String) throws -> String {
        for key in keys { if let value = self[key]?.stringValue, !value.isEmpty { return value } }
        throw CodexError.missingField("\(context).\(keys.joined(separator: "|"))")
    }
    func requireBool(_ key: String, context: String) throws -> Bool {
        guard let value = self[key]?.boolValue else { throw CodexError.invalidField("\(context).\(key)") }
        return value
    }
    func requireInt64(_ key: String, context: String) throws -> Int64 {
        guard let value = self[key]?.int64Value else { throw CodexError.invalidField("\(context).\(key)") }
        return value
    }
    func encoded(sortedKeys: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        if sortedKeys { encoder.outputFormatting = [.sortedKeys] }
        return try encoder.encode(self)
    }
    static func decode(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: data) }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Decimal(value)) }
    public init(floatLiteral value: Double) { self = .number(Decimal(value)) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
}
