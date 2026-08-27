import CoreFoundation
import Foundation

enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integer: Int? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    var bool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard case .array(let values) = self, values.indices.contains(index) else {
            return nil
        }
        return values[index]
    }

    fileprivate init(foundation value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if value.doubleValue.rounded() == value.doubleValue,
                      value.doubleValue >= Double(Int.min),
                      value.doubleValue <= Double(Int.max) {
                self = .integer(value.intValue)
            } else {
                self = .double(value.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map { try JSONValue(foundation: $0) })
        case let value as [String: Any]:
            self = .object(try value.mapValues { try JSONValue(foundation: $0) })
        default:
            throw JSONRPCMessageError.unsupportedValue
        }
    }

    fileprivate var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .integer(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationValue)
        case .object(let object): return object.mapValues(\.foundationValue)
        }
    }
}

enum RequestID: Hashable, Sendable {
    case integer(Int)
    case string(String)

    fileprivate init?(foundation value: Any?) {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            self = .integer(value.intValue)
        default:
            return nil
        }
    }

    fileprivate var foundationValue: Any {
        switch self {
        case .integer(let value): return value
        case .string(let value): return value
        }
    }
}

enum JSONRPCMessageKind: Equatable, Sendable {
    case request
    case response
    case notification
    case unrelated
}

enum JSONRPCMessageError: Error, Equatable, Sendable {
    case invalidUTF8
    case invalidTopLevel
    case unsupportedValue
}

struct JSONRPCMessage: Equatable, Sendable {
    let kind: JSONRPCMessageKind
    let id: RequestID?
    let method: String?
    let params: [String: JSONValue]?
    let result: JSONValue?
    let error: JSONValue?

    static func decode(line: String) throws -> JSONRPCMessage {
        guard let data = line.data(using: .utf8) else {
            throw JSONRPCMessageError.invalidUTF8
        }
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any] else {
            throw JSONRPCMessageError.invalidTopLevel
        }
        let id = RequestID(foundation: object["id"])
        let method = object["method"] as? String
        let params = try (object["params"] as? [String: Any])?
            .mapValues { try JSONValue(foundation: $0) }
        let result = try object["result"].map { try JSONValue(foundation: $0) }
        let error = try object["error"].map { try JSONValue(foundation: $0) }

        let kind: JSONRPCMessageKind
        switch (id, method) {
        case (.some, .some): kind = .request
        case (.some, .none): kind = .response
        case (.none, .some): kind = .notification
        case (.none, .none): kind = .unrelated
        }
        return JSONRPCMessage(
            kind: kind,
            id: id,
            method: method,
            params: params,
            result: result,
            error: error
        )
    }

    static func encodeRequest(
        id: RequestID,
        method: String,
        params: [String: JSONValue]
    ) throws -> Data {
        let object: [String: Any] = [
            "id": id.foundationValue,
            "method": method,
            "params": params.mapValues(\.foundationValue),
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func encodeResponse(
        id: RequestID,
        result: JSONValue
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["id": id.foundationValue, "result": result.foundationValue],
            options: [.sortedKeys]
        )
    }
}
