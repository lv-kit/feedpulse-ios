import Foundation

/// 契約（`error-response.schema.json`）のエラーコード。未知のコードは `.unknown`。
public enum FeedpulseErrorCode: Equatable, Hashable, Sendable {
    case invalidJSON
    case invalidPK
    case invalidPlatform
    case invalidApp
    case invalidChallenge
    case challengeExpired
    case attestationFailed
    case appNotRegistered
    case invalidSession
    case rateLimited
    case unknownProject
    case unknownForm
    case invalidForm
    case invalidIdempotencyKey
    case invalidFields
    case identityInvalid
    case payloadTooLarge
    case unsupportedMediaType
    case quotaExceeded
    case projectReadOnly
    case notFound
    case `internal`
    case unknown(String)

    private static let table: [(String, FeedpulseErrorCode)] = [
        ("invalid_json", .invalidJSON), ("invalid_pk", .invalidPK), ("invalid_platform", .invalidPlatform),
        ("invalid_app", .invalidApp), ("invalid_challenge", .invalidChallenge),
        ("challenge_expired", .challengeExpired), ("attestation_failed", .attestationFailed),
        ("app_not_registered", .appNotRegistered), ("invalid_session", .invalidSession),
        ("rate_limited", .rateLimited), ("unknown_project", .unknownProject), ("unknown_form", .unknownForm),
        ("invalid_form", .invalidForm), ("invalid_idempotency_key", .invalidIdempotencyKey),
        ("invalid_fields", .invalidFields), ("identity_invalid", .identityInvalid),
        ("payload_too_large", .payloadTooLarge), ("unsupported_media_type", .unsupportedMediaType),
        ("quota_exceeded", .quotaExceeded), ("project_read_only", .projectReadOnly),
        ("not_found", .notFound), ("internal", .internal),
    ]

    public init(rawValue: String) {
        self = Self.table.first { $0.0 == rawValue }?.1 ?? .unknown(rawValue)
    }

    /// 契約上の文字列（例: `invalid_session`）。
    public var rawValue: String {
        if case .unknown(let raw) = self { return raw }
        return Self.table.first { $0.1 == self }?.0 ?? ""
    }
}

/// `identity_invalid` のときの失敗理由（`code`）。
public enum FeedpulseIdentityFailure: Equatable, Sendable {
    case missing, malformed, alg, kid, signature, expired, lifetime, audience
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "missing": self = .missing
        case "malformed": self = .malformed
        case "alg": self = .alg
        case "kid": self = .kid
        case "signature": self = .signature
        case "expired": self = .expired
        case "lifetime": self = .lifetime
        case "audience": self = .audience
        default: self = .unknown(rawValue)
        }
    }
}

/// 項目単位の検証エラー（`invalid_fields` の `fields` の値）。
public enum FeedpulseFieldError: String, Codable, Equatable, Sendable, Error {
    case required
    case type
    case tooLong = "too_long"
    case invalidOption = "invalid_option"
    case invalidEmail = "invalid_email"
    case outOfRange = "out_of_range"
    case tooManyFiles = "too_many_files"
    case invalidUpload = "invalid_upload"
}

/// サーバーが返したエラー応答。
public struct FeedpulseAPIError: Equatable, Sendable {
    public var status: Int
    public var code: FeedpulseErrorCode
    /// `invalid_fields` のとき: ブロック ID → 検証エラー。
    public var fields: [String: FeedpulseFieldError]
    /// `identity_invalid` のとき: 身元確認トークンの失敗理由。
    public var identityFailure: FeedpulseIdentityFailure?
    /// `Retry-After`（秒）。429 などで付く。
    public var retryAfter: TimeInterval?

    public init(
        status: Int,
        code: FeedpulseErrorCode,
        fields: [String: FeedpulseFieldError] = [:],
        identityFailure: FeedpulseIdentityFailure? = nil,
        retryAfter: TimeInterval? = nil
    ) {
        self.status = status
        self.code = code
        self.fields = fields
        self.identityFailure = identityFailure
        self.retryAfter = retryAfter
    }
}

/// SDK が投げるエラー。
public enum FeedpulseError: Error, Equatable, Sendable {
    /// サーバーが契約のエラーコードで拒否した。
    case api(FeedpulseAPIError)
    /// 送信前のクライアント側検証で失敗した（サーバーへは送っていない）。
    case validation([String: FeedpulseFieldError])
    /// `GET /v1/config` の `forms` に無い formId。
    case unknownForm(String)
    /// 引数が不正（冪等キーの形式、`custom` に使えない値など）。
    case invalidArgument(String)
    /// この端末・環境では App Attest が使えない（シミュレーター等）。
    case attestationUnsupported
    /// 端末側の App Attest 呼び出しが失敗した。
    case attestationUnavailable(String)
    /// 通信できなかった（オフライン・タイムアウトなど）。
    case network(String)
    /// 応答が契約の形ではなかった。
    case invalidResponse(status: Int)
    /// 呼び出しがキャンセルされた。
    case cancelled

    /// サーバーのエラーコード。`.api` 以外は nil。
    public var apiCode: FeedpulseErrorCode? {
        if case .api(let e) = self { return e.code }
        return nil
    }

    /// 時間を置いて同じ送信を再試行して意味があるか。
    public var isRetryable: Bool {
        switch self {
        case .network: return true
        case .invalidResponse(let status): return status >= 500
        case .api(let e): return (e.status == 429 && e.code != .quotaExceeded) || e.status >= 500
        default: return false
        }
    }
}
