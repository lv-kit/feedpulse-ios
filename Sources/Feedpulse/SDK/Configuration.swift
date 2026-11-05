import Foundation

/// SDK の設定。`Feedpulse.configure(...)` が組み立てる。
public struct FeedpulseConfiguration: Sendable {
    /// 本番の ingest。
    public static let productionBaseURL = URL(string: "https://ingest.feedpulse.stargazy.xyz")!

    /// プロジェクトの公開鍵（`pk_...`）。
    public var publicKey: String
    public var baseURL: URL
    /// 登録したアプリの bundle ID。App Attest はこの値と Team ID で検証される。
    public var appId: String
    public var attestation: FeedpulseAttestationProvider
    /// 通信に使うセッション。省略時は SDK が `ephemeral` 構成で作る。
    public var urlSession: URLSession?
    /// 1 回のリクエストの最大試行回数（再送を含む）。
    public var maxAttempts: Int
    public var requestTimeout: TimeInterval
    /// `Retry-After` がこの秒数以内なら待って再送する。超えるときは待たずに `rateLimited` を投げる。
    public var maxRetryAfterWait: TimeInterval
    /// `context.auto`（OS・ロケール・タイムゾーン）を送るか。`target` は渡したときだけ送る。
    public var sendsAutoContext: Bool
    /// 項目定義のキャッシュを置くディレクトリ。省略時は Caches。`nil` 以外でも書き込めなければキャッシュ無しで動く。
    public var cacheDirectory: URL?

    public init(
        publicKey: String,
        baseURL: URL = FeedpulseConfiguration.productionBaseURL,
        appId: String? = nil,
        attestation: FeedpulseAttestationProvider? = nil,
        urlSession: URLSession? = nil,
        maxAttempts: Int = 3,
        requestTimeout: TimeInterval = 15,
        maxRetryAfterWait: TimeInterval = 30,
        sendsAutoContext: Bool = true,
        cacheDirectory: URL? = nil
    ) {
        let resolvedAppId = appId ?? Bundle.main.bundleIdentifier ?? ""
        self.publicKey = publicKey
        self.baseURL = baseURL
        self.appId = resolvedAppId
        self.attestation = attestation ?? AppAttestProvider.system(publicKey: publicKey, appId: resolvedAppId)
        self.urlSession = urlSession
        self.maxAttempts = max(1, maxAttempts)
        self.requestTimeout = requestTimeout
        self.maxRetryAfterWait = maxRetryAfterWait
        self.sendsAutoContext = sendsAutoContext
        self.cacheDirectory = cacheDirectory
    }
}

/// 時刻・待機・乱数など、テストで差し替える依存。
struct FeedpulseEnvironment: @unchecked Sendable {
    var now: () -> Date = { Date() }
    var sleep: (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
    /// 0..<1。再送の揺らぎ（jitter）に使う。
    var random: () -> Double = { Double.random(in: 0..<1) }
    var autoContext: () -> AutoContext = { AutoContext.current() }
}

struct AutoContext: Encodable, Equatable {
    var os: String
    var locale: String
    var timezone: String

    static func current() -> AutoContext {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let name = "iOS"
        #elseif os(macOS)
        let name = "macOS"
        #else
        let name = "Apple"
        #endif
        var os = "\(name) \(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { os += ".\(v.patchVersion)" }
        return .init(
            os: os,
            locale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            timezone: TimeZone.current.identifier
        )
    }
}
