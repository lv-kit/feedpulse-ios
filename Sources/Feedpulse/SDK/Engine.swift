import Foundation

/// 通信とキャッシュの本体。UI 状態は持たない（`FeedpulseClient` が公開する）。
actor FeedpulseEngine {
    struct ConfigResult {
        var config: FeedpulseConfig
        /// 通信に失敗して前回値を返した。
        var isStale: Bool
        /// 前回値を返した理由。
        var error: FeedpulseError?
    }

    private let config: FeedpulseConfiguration
    private let transport: Transport
    private let sessions: SessionManager
    private let store: ConfigCacheStore
    private let env: FeedpulseEnvironment
    private var cache: CachedConfig?

    init(config: FeedpulseConfiguration, env: FeedpulseEnvironment = .init(), store: ConfigCacheStore? = nil) {
        let urlSession: URLSession
        if let s = config.urlSession { urlSession = s } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = config.requestTimeout
            urlSession = URLSession(configuration: c)
        }
        let transport = Transport(session: urlSession, baseURL: config.baseURL, timeout: config.requestTimeout)
        self.config = config
        self.env = env
        self.transport = transport
        self.sessions = SessionManager(transport: transport, config: config, env: env)
        let store = store ?? FileConfigCacheStore(directory: config.cacheDirectory, baseURL: config.baseURL, publicKey: config.publicKey)
        self.store = store
        self.cache = store.load()
    }

    var cachedConfig: FeedpulseConfig? { cache?.config }

    private var retrier: Retrier {
        Retrier(maxAttempts: config.maxAttempts, maxRetryAfterWait: config.maxRetryAfterWait, env: env)
    }

    // MARK: config

    /// 項目定義を返す。鮮度内のキャッシュがあれば通信しない（`force` なら必ず通信する）。
    /// 通信に失敗したら前回値を返し、前回値も無いときだけ投げる。
    func loadConfig(force: Bool) async throws -> ConfigResult {
        if !force, let cache, (0..<cache.ttl).contains(env.now().timeIntervalSince(cache.fetchedAt)) {
            return .init(config: cache.config, isStale: false, error: nil)
        }
        do {
            let response = try await authorized(method: "GET", path: configPath)
            guard let decoded = try? JSONDecoder().decode(FeedpulseConfig.self, from: response.body) else {
                throw FeedpulseError.invalidResponse(status: response.status)
            }
            let fresh = CachedConfig(config: decoded, fetchedAt: env.now(), ttl: CacheControl.maxAge(response.headers["cache-control"]))
            cache = fresh
            store.save(fresh)
            return .init(config: decoded, isStale: false, error: nil)
        } catch let error as FeedpulseError {
            if case .cancelled = error { throw error }
            if let cache { return .init(config: cache.config, isStale: true, error: error) }
            throw error
        }
    }

    private var configPath: String {
        var c = URLComponents()
        c.path = "/v1/config"
        c.queryItems = [URLQueryItem(name: "pk", value: config.publicKey)]
        return c.string ?? "/v1/config"
    }

    /// 送信先の項目定義。キャッシュに無ければ 1 回だけ取得する。
    func form(id: String) async throws -> FeedpulseForm {
        if let f = cache?.config.forms.first(where: { $0.id == id }) { return f }
        // キャッシュが鮮度内でも、無いフォームは公開されたばかりかもしれないので 1 回だけ取り直す。
        let result = try await loadConfig(force: true)
        guard let f = result.config.forms.first(where: { $0.id == id }) else { throw FeedpulseError.unknownForm(id) }
        return f
    }

    // MARK: submit

    private struct SubmitBody: Encodable {
        struct Context: Encodable {
            var auto: Auto?
            var custom: [String: FeedpulseCustomValue]?
            var identity: String?
        }
        struct Auto: Encodable {
            var os: String?
            var locale: String?
            var timezone: String?
            var target: FeedpulseTarget?
        }
        var formId: String
        var idempotencyKey: String
        var fields: [String: FeedpulseValue]
        var context: Context?
    }

    private struct SubmitResponse: Decodable { var id: String }

    /// 検証済みの値を送る。再送（ネットワークエラー・429・5xx）は同じ冪等キーで行う。
    func submit(_ submission: FeedpulseSubmission, fields: [String: FeedpulseValue], identity: String?) async throws -> FeedpulseReceipt {
        var auto = SubmitBody.Auto()
        if config.sendsAutoContext {
            let a = env.autoContext()
            auto.os = a.os; auto.locale = a.locale; auto.timezone = a.timezone
        }
        auto.target = submission.target.map { TargetSanitizer.sanitize($0) }
        let hasAuto = auto.os != nil || auto.target != nil
        let context = SubmitBody.Context(
            auto: hasAuto ? auto : nil,
            custom: submission.custom.isEmpty ? nil : submission.custom,
            identity: identity
        )
        let hasContext = context.auto != nil || context.custom != nil || context.identity != nil
        let body = try JSONEncoder().encode(SubmitBody(
            formId: submission.formId, idempotencyKey: submission.idempotencyKey,
            fields: fields, context: hasContext ? context : nil
        ))
        let response = try await authorized(method: "POST", path: "/v1/submit", body: body)
        guard let decoded = try? JSONDecoder().decode(SubmitResponse.self, from: response.body) else {
            throw FeedpulseError.invalidResponse(status: response.status)
        }
        return FeedpulseReceipt(id: decoded.id)
    }

    // MARK: 認証付きリクエスト

    /// Bearer を付けて送る。再送（ネットワークエラー・429・5xx）はこの 1 リクエストだけに掛ける
    /// （セッション取得は `SessionManager` が自分で再送するので、二重に掛けない）。
    /// `invalid_session` なら 1 回だけセッションを取り直して同じ内容を送り直す。
    private func authorized(method: String, path: String, body: Data? = nil) async throws -> HTTPResponse {
        var token = try await sessions.token()
        var refreshed = false
        while true {
            do {
                return try await retrier.run {
                    let response = try await self.transport.send(
                        method: method, path: path,
                        headers: ["X-FeedPulse-Platform": "ios", "Authorization": "Bearer \(token)"],
                        body: body
                    )
                    if response.isSuccess { return response }
                    throw APIErrorDecoder.decode(response)
                }
            } catch FeedpulseError.api(let e) where e.code == .invalidSession && !refreshed {
                refreshed = true
                await sessions.invalidate(token)
                token = try await sessions.token()
            }
        }
    }
}
