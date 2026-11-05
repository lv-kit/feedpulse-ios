import Foundation

/// ネイティブセッション（900 秒）の取得とキャッシュ。同時に呼ばれても取得は 1 回にまとめる。
actor SessionManager {
    /// 期限のこの秒数前になったら取り直す。
    static let refreshMargin: TimeInterval = 30

    private let transport: Transport
    private let config: FeedpulseConfiguration
    private let env: FeedpulseEnvironment
    private var cached: (token: String, expiresAt: Date)?
    private var inFlight: Task<String, Error>?

    init(transport: Transport, config: FeedpulseConfiguration, env: FeedpulseEnvironment) {
        self.transport = transport
        self.config = config
        self.env = env
    }

    func token() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(env.now()) > Self.refreshMargin { return cached.token }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.acquire() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// サーバーが `invalid_session` を返したトークンを捨てる（別の呼び出しがすでに取り直していたら何もしない）。
    func invalidate(_ token: String) {
        if cached?.token == token { cached = nil }
    }

    private func acquire() async throws -> String {
        let retrier = Retrier(maxAttempts: config.maxAttempts, maxRetryAfterWait: config.maxRetryAfterWait, env: env)
        let session = try await retrier.run { try await self.acquireOnce() }
        cached = (session.session, Date(timeIntervalSince1970: TimeInterval(session.expiresAt)))
        return session.session
    }

    private struct SessionResponse: Decodable { var session: String; var expiresAt: Int }
    private struct ChallengeResponse: Decodable { var challenge: String; var expiresAt: Int }

    /// challenge → 証明 → session を 1 周する。challenge の期限切れと iOS の鍵の作り直しはここで吸収する。
    private func acquireOnce() async throws -> SessionResponse {
        var challengeRetries = 0
        var keyResetUsed = false
        while true {
            let challenge: ChallengeResponse = try await post("/v1/native/challenge", ["pk": config.publicKey])
            let payload = try await config.attestation.payload(forChallenge: challenge.challenge)
            let body: [String: Any] = [
                "pk": config.publicKey, "platform": "ios", "appId": config.appId,
                "challenge": challenge.challenge, "attestation": payload.json,
            ]
            do {
                let response: SessionResponse = try await post("/v1/native/session", body)
                await config.attestation.accepted(payload)
                return response
            } catch FeedpulseError.api(let e) {
                switch e.code {
                case .attestationFailed:
                    // 登録済みの鍵が拒否された（サーバー側で消えた等）。鍵を捨てて attestation からやり直す。
                    await config.attestation.rejected(payload)
                    if payload.isAssertion, !keyResetUsed { keyResetUsed = true; continue }
                    throw FeedpulseError.api(e)
                case .challengeExpired, .invalidChallenge:
                    // 通信が遅く期限が切れた、または再利用された。取り直す。
                    if challengeRetries < 2 { challengeRetries += 1; continue }
                    throw FeedpulseError.api(e)
                default:
                    throw FeedpulseError.api(e)
                }
            }
        }
    }

    private func post<T: Decodable>(_ path: String, _ json: [String: Any]) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let response = try await transport.send(method: "POST", path: path, body: body)
        guard response.isSuccess else { throw APIErrorDecoder.decode(response) }
        guard let value = try? JSONDecoder().decode(T.self, from: response.body) else {
            throw FeedpulseError.invalidResponse(status: response.status)
        }
        return value
    }
}
