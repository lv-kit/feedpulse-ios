import Foundation

/// 任意の JSON 値。`widget` の保持とキャッシュの往復に使う。
public enum FeedpulseJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FeedpulseJSONValue])
    case object([String: FeedpulseJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([FeedpulseJSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: FeedpulseJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - 項目定義

/// ブロックの種類。未知の種類は `.unknown`（将来の追加でキャッシュの読み込みが壊れないように）。
public enum FeedpulseBlockType: Codable, Equatable, Hashable, Sendable {
    case shortText, longText, email, number, select, radio, checkbox, rating, image, file
    case unknown(String)

    private static let table: [(String, FeedpulseBlockType)] = [
        ("short_text", .shortText), ("long_text", .longText), ("email", .email), ("number", .number),
        ("select", .select), ("radio", .radio), ("checkbox", .checkbox), ("rating", .rating),
        ("image", .image), ("file", .file),
    ]

    public init(rawValue: String) {
        self = Self.table.first { $0.0 == rawValue }?.1 ?? .unknown(rawValue)
    }

    public var rawValue: String {
        if case .unknown(let raw) = self { return raw }
        return Self.table.first { $0.1 == self }?.0 ?? ""
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct FeedpulseOption: Codable, Equatable, Sendable {
    public var value: String
    public var label: String
}

public struct FeedpulseBlock: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var type: FeedpulseBlockType
    public var label: String
    public var required: Bool
    public var maxLength: Int?
    public var min: Double?
    public var max: Double?
    public var options: [FeedpulseOption]?
    public var maxFiles: Int?
    public var maxTotalBytes: Int?

    public init(
        id: String, type: FeedpulseBlockType, label: String, required: Bool,
        maxLength: Int? = nil, min: Double? = nil, max: Double? = nil, options: [FeedpulseOption]? = nil,
        maxFiles: Int? = nil, maxTotalBytes: Int? = nil
    ) {
        self.id = id; self.type = type; self.label = label; self.required = required
        self.maxLength = maxLength; self.min = min; self.max = max; self.options = options
        self.maxFiles = maxFiles; self.maxTotalBytes = maxTotalBytes
    }
}

public struct FeedpulseFormDefinition: Codable, Equatable, Sendable {
    /// 「画面上の該当箇所を選択」を出してよいか。無い定義は false。
    public var allowTarget: Bool?
    public var blocks: [FeedpulseBlock]

    public init(allowTarget: Bool? = nil, blocks: [FeedpulseBlock]) {
        self.allowTarget = allowTarget
        self.blocks = blocks
    }
}

public struct FeedpulseForm: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var slug: String
    public var name: String
    /// `inquiry` / `bug` / `improvement`（将来の追加に備えて文字列のまま持つ）。
    public var type: String
    /// 公開済みの版。キャッシュの更新判定に使う。
    public var version: Int
    public var definition: FeedpulseFormDefinition

    public init(id: String, slug: String, name: String, type: String, version: Int, definition: FeedpulseFormDefinition) {
        self.id = id; self.slug = slug; self.name = name; self.type = type
        self.version = version; self.definition = definition
    }
}

/// `GET /v1/config` の応答。
public struct FeedpulseConfig: Codable, Equatable, Sendable {
    public var widget: [String: FeedpulseJSONValue]
    public var forms: [FeedpulseForm]

    public init(widget: [String: FeedpulseJSONValue] = [:], forms: [FeedpulseForm]) {
        self.widget = widget
        self.forms = forms
    }
}

// MARK: - 入力値

/// 項目の入力値。型はブロックの種類に従う（`short_text` などは `.text`、`number` / `rating` は `.number`、
/// `checkbox` / `image` / `file` は `.list`）。
public enum FeedpulseValue: Equatable, Sendable, Encodable,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral {
    case text(String)
    case number(Double)
    case list([String])

    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: String...) { self = .list(elements) }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .list(let v): try c.encode(v)
        }
    }
}

/// `context.custom` の値（文字列・数値・真偽値のみ）。
public enum FeedpulseCustomValue: Equatable, Sendable, Encodable,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        }
    }
}

/// 送信 1 件。`idempotencyKey` は作成時に SDK が生成する。**失敗後に再送するときは同じ値を渡し直す**
/// （サーバーは同じキーを二重に保存しない）。
public struct FeedpulseSubmission: Equatable, Sendable {
    public var formId: String
    public var values: [String: FeedpulseValue]
    /// 該当箇所ピッカーの結果。`context.auto.target` に載る。
    public var target: FeedpulseTarget?
    public var custom: [String: FeedpulseCustomValue]
    public let idempotencyKey: String

    public init(
        formId: String,
        values: [String: FeedpulseValue],
        target: FeedpulseTarget? = nil,
        custom: [String: FeedpulseCustomValue] = [:],
        idempotencyKey: String = FeedpulseSubmission.generateIdempotencyKey()
    ) {
        self.formId = formId
        self.values = values
        self.target = target
        self.custom = custom
        self.idempotencyKey = idempotencyKey
    }

    /// `^[A-Za-z0-9_-]{16,64}$` を満たす 22 文字（乱数 16 バイトの base64url）。
    public static func generateIdempotencyKey() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isValidIdempotencyKey(_ key: String) -> Bool {
        let scalars = key.unicodeScalars
        guard (16...64).contains(scalars.count) else { return false }
        return scalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "_" || $0 == "-"
        }
    }
}

/// 受理された送信（202）。
public struct FeedpulseReceipt: Equatable, Sendable {
    public var id: String
}
