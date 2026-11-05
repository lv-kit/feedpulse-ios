import XCTest
import CryptoKit
@testable import Feedpulse

/// `contract.json`（lv-kit/feedpulse-web `packages/shared/src/native/fixtures`）を読み、HTTP を差し替えて SDK を通す。
@MainActor
final class ContractTests: XCTestCase {
    let challenge = String(repeating: "A", count: 48)

    // MARK: ヘルパー

    /// `{{...}}` は任意の文字列に一致する。`ignoring` のパス（例: `context.auto`）は比較しない。
    func assertBody(_ actual: [String: Any]?, equals expected: Any?, ignoring: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) {
        guard let actual, let expected else { return XCTFail("body missing", file: file, line: line) }
        let problems = Self.diff(actual, expected, path: "", ignoring: ignoring)
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"), file: file, line: line)
    }

    static func diff(_ a: Any, _ e: Any, path: String, ignoring: Set<String>) -> [String] {
        if ignoring.contains(path) { return [] }
        if let es = e as? String, es.hasPrefix("{{"), es.hasSuffix("}}") { return a is String ? [] : ["\(path): string expected"] }
        if let ed = e as? [String: Any] {
            guard var ad = a as? [String: Any] else { return ["\(path): object expected"] }
            for k in ignoring where k.hasPrefix(path.isEmpty ? "" : path + ".") {
                ad[String(k.dropFirst(path.isEmpty ? 0 : path.count + 1))] = nil
            }
            var out: [String] = []
            for k in Set(ad.keys).union(ed.keys) {
                let p = path.isEmpty ? k : "\(path).\(k)"
                if ignoring.contains(p) { continue }
                guard let av = ad[k] else { out.append("\(p): missing"); continue }
                guard let ev = ed[k] else { out.append("\(p): unexpected"); continue }
                out += diff(av, ev, path: p, ignoring: ignoring)
            }
            return out
        }
        if let ea = e as? [Any] {
            guard let aa = a as? [Any], aa.count == ea.count else { return ["\(path): array mismatch"] }
            return zip(aa, ea).enumerated().flatMap { diff($1.0, $1.1, path: "\(path)[\($0)]", ignoring: ignoring) }
        }
        if let en = e as? NSNumber, let an = a as? NSNumber { return en == an ? [] : ["\(path): \(an) != \(en)"] }
        if let es = e as? String, let s = a as? String { return es == s ? [] : ["\(path): \(s) != \(es)"] }
        return ["\(path): type mismatch"]
    }

    struct Harness {
        var client: FeedpulseClient
        var engine: FeedpulseEngine
        var clock: TestClock
        var attest: FakeAppAttest
        var keyStore: InMemoryKeyStore
    }

    func makeHarness(
        keyId: String? = nil, maxAttempts: Int = 3, maxRetryAfterWait: TimeInterval = 30,
        store: ConfigCacheStore? = nil, clock: TestClock = TestClock()
    ) -> Harness {
        let attest = FakeAppAttest()
        let keyStore = InMemoryKeyStore(keyId)
        let config = FeedpulseConfiguration(
            publicKey: "pk_example", baseURL: URL(string: "https://ingest.example.test")!, appId: "com.example.app",
            attestation: AppAttestProvider(service: attest, keyStore: keyStore),
            urlSession: makeMockSession(), maxAttempts: maxAttempts, maxRetryAfterWait: maxRetryAfterWait
        )
        let engine = FeedpulseEngine(config: config, env: clock.environment(), store: store ?? MemoryConfigStore())
        return Harness(client: FeedpulseClient(engine: engine), engine: engine, clock: clock, attest: attest, keyStore: keyStore)
    }

    /// fixture の応答を返すモック。`overrides` に無い経路は成功 fixture。
    func serve(_ overrides: [String: (RecordedRequest) -> MockResponse] = [:]) {
        let ok = Contract.fixture
        MockURLProtocol.reset { req in
            if let o = overrides[req.path] { return o(req) }
            switch req.path {
            case "/v1/native/challenge": return ok("challenge-ok").mockResponse()
            case "/v1/native/session": return ok("session-ok-app-attest-attestation").mockResponse()
            case "/v1/config": return ok("config-ok").mockResponse()
            case "/v1/submit": return ok("submit-ok").mockResponse()
            default: return .json(404, ["error": "not_found"])
            }
        }
    }

    func requests(_ path: String) -> [RecordedRequest] { MockURLProtocol.recorded.filter { $0.path == path } }

    var formId: String { "6f1d2c3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f" }

    // MARK: fixture 自体

    func testFixtureResponsesConformToSchemas() throws {
        XCTAssertGreaterThan(Contract.fixtures.count, 15)
        for f in Contract.fixtures.values {
            guard let schema = f.responseSchema else { continue }
            XCTAssertEqual(try Contract.violations(f.responseBody, schema: schema), [], f.name)
        }
    }

    // MARK: セッション取得

    func testAttestationFlowMatchesFixtures() async throws {
        let h = makeHarness()
        serve()
        let forms = try await h.client.refresh()

        let calls = MockURLProtocol.recorded
        XCTAssertEqual(calls.map(\.path), ["/v1/native/challenge", "/v1/native/session", "/v1/config"])
        assertBody(calls[0].json, equals: Contract.fixture("challenge-ok").requestBody)
        assertBody(calls[1].json, equals: Contract.fixture("session-ok-app-attest-attestation").requestBody)
        XCTAssertEqual(try Contract.violations(calls[0].json!, schema: "native-challenge-request"), [])
        XCTAssertEqual(try Contract.violations(calls[1].json!, schema: "native-session-request"), [])
        XCTAssertNil(calls[0].headers["origin"])
        XCTAssertEqual(calls[2].pathWithQuery, "/v1/config?pk=pk_example")
        XCTAssertEqual(calls[2].headers["x-feedpulse-platform"], "ios")
        XCTAssertEqual(calls[2].headers["authorization"], "Bearer eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJleGFtcGxlIn0.c2lnbmF0dXJl")
        XCTAssertNil(calls[2].headers["origin"])

        XCTAssertEqual(forms.first?.id, formId)
        XCTAssertEqual(forms.first?.version, 3)
        XCTAssertEqual(forms.first?.definition.allowTarget, true)
        XCTAssertEqual(forms.first?.definition.blocks.map(\.id), ["title", "body", "severity"])
        // clientDataHash は SHA256(challenge の UTF-8)
        XCTAssertEqual(h.attest.lastClientDataHash, Data(SHA256.hash(data: Data(challenge.utf8))))
        // 受理されたので keyId が保存される
        XCTAssertEqual(h.keyStore.load(), "a2V5SWQ=")
    }

    func testAssertionFlowMatchesFixture() async throws {
        let h = makeHarness(keyId: "a2V5SWQ=")
        serve(["/v1/native/session": { _ in Contract.fixture("session-ok-app-attest-assertion").mockResponse() }])
        try await h.client.refresh()
        let session = requests("/v1/native/session")[0]
        assertBody(session.json, equals: Contract.fixture("session-ok-app-attest-assertion").requestBody)
        XCTAssertEqual(h.attest.generatedKeys, 0)
        XCTAssertEqual(h.attest.assertions, 1)
    }

    func testAttestationFailedOnFreshKeyDoesNotRetryAndDropsKey() async throws {
        let h = makeHarness()
        serve(["/v1/native/session": { _ in Contract.fixture("session-attestation-failed").mockResponse() }])
        do {
            try await h.client.refresh()
            XCTFail("should throw")
        } catch let FeedpulseError.api(e) {
            XCTAssertEqual(e.code, .attestationFailed)
            XCTAssertEqual(e.status, 403)
        }
        XCTAssertEqual(requests("/v1/native/session").count, 1)
        XCTAssertNil(h.keyStore.load())
    }

    func testRejectedAssertionRecreatesKeyOnce() async throws {
        let h = makeHarness(keyId: "b2xkS2V5")
        var sessionCalls = 0
        serve(["/v1/native/session": { _ in
            sessionCalls += 1
            return sessionCalls == 1 ? Contract.fixture("session-attestation-failed").mockResponse()
                                     : Contract.fixture("session-ok-app-attest-attestation").mockResponse()
        }])
        try await h.client.refresh()
        let sessions = requests("/v1/native/session").map { ($0.json?["attestation"] as? [String: Any])?["type"] as? String }
        XCTAssertEqual(sessions, ["app_attest_assertion", "app_attest_attestation"])
        XCTAssertEqual(requests("/v1/native/challenge").count, 2)   // challenge は 1 回限りなので取り直す
        XCTAssertEqual(h.keyStore.load(), "a2V5SWQ=")
    }

    func testChallengeExpiredFetchesNewChallenge() async throws {
        let h = makeHarness()
        var n = 0
        serve(["/v1/native/session": { _ in
            n += 1
            return n == 1 ? Contract.fixture("session-challenge-expired").mockResponse()
                          : Contract.fixture("session-ok-app-attest-attestation").mockResponse()
        }])
        try await h.client.refresh()
        XCTAssertEqual(requests("/v1/native/challenge").count, 2)
        XCTAssertEqual(h.clock.sleeps, [])   // 待たずに取り直す
    }

    func testChallengeExpiredGivesUpAfterThreeRounds() async {
        let h = makeHarness()
        serve(["/v1/native/session": { _ in Contract.fixture("session-challenge-expired").mockResponse() }])
        do { try await h.client.refresh(); XCTFail() } catch {
            XCTAssertEqual((error as? FeedpulseError)?.apiCode, .challengeExpired)
        }
        XCTAssertEqual(requests("/v1/native/session").count, 3)
    }

    func testAppNotRegisteredIsNotRetried() async {
        let h = makeHarness()
        serve(["/v1/native/session": { _ in Contract.fixture("session-app-not-registered").mockResponse() }])
        do { try await h.client.refresh(); XCTFail() } catch {
            XCTAssertEqual((error as? FeedpulseError)?.apiCode, .appNotRegistered)
        }
        XCTAssertEqual(requests("/v1/native/session").count, 1)
        XCTAssertTrue(h.clock.sleeps.isEmpty)
    }

    func testSessionRateLimitHonorsRetryAfter() async {
        let h = makeHarness()
        serve(["/v1/native/session": { _ in Contract.fixture("session-rate-limited").mockResponse() }])
        do { try await h.client.refresh(); XCTFail() } catch let FeedpulseError.api(e) {
            XCTAssertEqual(e.code, .rateLimited)
            XCTAssertEqual(e.retryAfter, 30)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(h.clock.sleeps, [30, 30])   // 3 回試行 = 2 回待つ
    }

    func testLongRetryAfterIsNotWaited() async {
        let h = makeHarness(maxRetryAfterWait: 10)
        serve(["/v1/native/session": { _ in Contract.fixture("session-rate-limited").mockResponse() }])
        do { try await h.client.refresh(); XCTFail() } catch {
            XCTAssertEqual((error as? FeedpulseError)?.apiCode, .rateLimited)
        }
        XCTAssertEqual(requests("/v1/native/session").count, 1)
        XCTAssertTrue(h.clock.sleeps.isEmpty)
    }

    func testUnsupportedDeviceThrowsAttestationUnsupported() async {
        let h = makeHarness()
        h.attest.isSupported = false
        serve()
        do { try await h.client.refresh(); XCTFail() } catch {
            XCTAssertEqual(error as? FeedpulseError, .attestationUnsupported)
        }
    }

    // MARK: config

    func testConfigSessionExpiredRefreshesSessionOnce() async throws {
        let h = makeHarness()
        var sessions = 0
        serve([
            "/v1/native/session": { _ in
                sessions += 1
                return .json(200, ["session": "aaa.bbb.ccc\(sessions)", "expiresAt": 1_700_000_900])
            },
            "/v1/config": { req in
                req.headers["authorization"] == "Bearer aaa.bbb.ccc1"
                    ? Contract.fixture("config-session-expired").mockResponse()
                    : Contract.fixture("config-ok").mockResponse()
            },
        ])
        let forms = try await h.client.refresh()
        XCTAssertEqual(forms.count, 1)
        XCTAssertEqual(requests("/v1/config").map { $0.headers["authorization"] }, ["Bearer aaa.bbb.ccc1", "Bearer aaa.bbb.ccc2"])
        XCTAssertEqual(sessions, 2)
    }

    func testConfigRateLimitedThenFailsWithRetryAfter() async {
        let h = makeHarness()
        serve(["/v1/config": { _ in Contract.fixture("config-rate-limited").mockResponse() }])
        do { try await h.client.refresh(); XCTFail() } catch let FeedpulseError.api(e) {
            XCTAssertEqual(e.code, .rateLimited)
            XCTAssertEqual(e.retryAfter, 30)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(requests("/v1/config").count, 3)
        XCTAssertEqual(h.clock.sleeps, [30, 30])
    }

    // MARK: submit

    func loadedHarness() async throws -> Harness {
        let h = makeHarness()
        serve()
        try await h.client.refresh()
        return h
    }

    func testSubmitMatchesFixture() async throws {
        let h = try await loadedHarness()
        let fx = Contract.fixture("submit-ok")
        let key = (fx.requestBody as! [String: Any])["idempotencyKey"] as! String
        let receipt = try await h.client.submit(FeedpulseSubmission(
            formId: formId, values: ["title": "ログインできない", "severity": "high"],
            custom: ["plan": "pro"], idempotencyKey: key))
        XCTAssertEqual(receipt.id, "0b9f1c2d-3e4f-4a5b-8c6d-7e8f9a0b1c2d")

        let req = requests("/v1/submit")[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.headers["content-type"], "application/json")
        XCTAssertEqual(req.headers["x-feedpulse-platform"], "ios")
        XCTAssertNil(req.headers["origin"])
        assertBody(req.json, equals: fx.requestBody, ignoring: ["context.auto"])
        XCTAssertEqual(try Contract.violations(req.json!, schema: "submit-request"), [])
        let auto = (req.json?["context"] as? [String: Any])?["auto"] as? [String: Any]
        XCTAssertEqual(auto?["os"] as? String, "iOS 17.2")
        XCTAssertEqual(auto?["locale"] as? String, "ja-JP")
        XCTAssertEqual(auto?["timezone"] as? String, "Asia/Tokyo")
    }

    func testSubmitWithIdentityAndTarget() async throws {
        let h = try await loadedHarness()
        let fx = Contract.fixture("submit-ok-with-identity")
        h.client.identify("  hdr.payload.sig  ")
        XCTAssertTrue(h.client.isIdentified)
        let target = FeedpulseTarget(screen: "Checkout", id: "pay-button", path: "UIWindow>UIButton[0]", label: "Pay")
        try await h.client.submit(FeedpulseSubmission(
            formId: formId, values: ["title": "ログインできない", "severity": "high"], target: target))
        let req = requests("/v1/submit")[0]
        let ctx = req.json?["context"] as? [String: Any]
        XCTAssertEqual(ctx?["identity"] as? String, "hdr.payload.sig")
        XCTAssertEqual(((ctx?["auto"] as? [String: Any])?["target"] as? [String: Any])?["id"] as? String, "pay-button")
        XCTAssertEqual(try Contract.violations(req.json!, schema: "submit-request"), [])
        // fixture と同じ形（context は identity のみ + SDK の auto）
        assertBody(req.json, equals: fx.requestBody, ignoring: ["context.auto", "idempotencyKey"])

        h.client.identify(nil)
        XCTAssertFalse(h.client.isIdentified)
        try await h.client.submit(FeedpulseSubmission(formId: formId, values: ["title": "t", "severity": "low"]))
        let second = requests("/v1/submit")[1].json?["context"] as? [String: Any]
        XCTAssertNil(second?["identity"])
    }

    /// サーバーの 422 を `fields` ごとに受け取れる。クライアント検証も fixture と同じ判定になる。
    func testInvalidFieldsMappedAndLocalValidationAgrees() async throws {
        let h = try await loadedHarness()
        let fx = Contract.fixture("submit-invalid-fields")
        let expected = (fx.responseBody as! [String: Any])["fields"] as! [String: String]

        // サーバー応答のマッピング（クライアント検証を通さず engine へ直接）
        MockURLProtocol.reset { req in
            req.path == "/v1/submit" ? fx.mockResponse() : Contract.fixture("config-ok").mockResponse()
        }
        do {
            _ = try await h.engine.submit(FeedpulseSubmission(formId: formId, values: [:]), fields: ["severity": "urgent"], identity: nil)
            XCTFail()
        } catch let FeedpulseError.api(e) {
            XCTAssertEqual(e.code, .invalidFields)
            XCTAssertEqual(e.status, 422)
            XCTAssertEqual(e.fields.mapValues(\.rawValue), expected)
        }
        XCTAssertEqual(requests("/v1/submit").count, 1)   // 422 は再送しない

        // 同じ入力をクライアント側で検証 → 同じエラー
        let form = h.client.forms[0]
        let local = form.validate(["severity": "urgent"])
        XCTAssertEqual(local.errors.mapValues(\.rawValue), expected)
    }

    func testClientValidationBlocksSubmitWithoutNetwork() async throws {
        let h = try await loadedHarness()
        do {
            try await h.client.submit(FeedpulseSubmission(formId: formId, values: ["severity": "urgent"]))
            XCTFail()
        } catch let FeedpulseError.validation(errors) {
            XCTAssertEqual(errors, ["title": .required, "severity": .invalidOption])
        }
        XCTAssertTrue(requests("/v1/submit").isEmpty)
    }

    func testIdentityInvalidIsSurfacedWithCodeAndNotRetried() async throws {
        let h = try await loadedHarness()
        serve(["/v1/submit": { _ in Contract.fixture("submit-identity-invalid").mockResponse() }])
        h.client.identify("expired.jwt.token")
        do {
            try await h.client.submit(FeedpulseSubmission(formId: formId, values: ["title": "t", "severity": "low"]))
            XCTFail()
        } catch let FeedpulseError.api(e) {
            XCTAssertEqual(e.code, .identityInvalid)
            XCTAssertEqual(e.identityFailure, .expired)
            XCTAssertEqual(e.status, 401)
        }
        XCTAssertEqual(requests("/v1/submit").count, 1)
    }

    func testSubmitSessionExpiredRetriesWithSameIdempotencyKey() async throws {
        let h = try await loadedHarness()
        var sessions = 1   // loadedHarness で 1 回取得済み
        var submits = 0
        serve([
            "/v1/native/session": { _ in
                sessions += 1
                return .json(200, ["session": "new.session.tok\(sessions)", "expiresAt": 1_700_000_900])
            },
            "/v1/submit": { _ in
                submits += 1
                return submits == 1 ? Contract.fixture("submit-session-expired").mockResponse() : Contract.fixture("submit-ok").mockResponse()
            },
        ])
        // 取得済みセッションは有効扱いなので、1 回目の 401 で取り直す
        try await h.client.submit(FeedpulseSubmission(formId: formId, values: ["title": "t", "severity": "low"], idempotencyKey: "abcdefghijklmnop"))
        let sent = requests("/v1/submit")
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.map { $0.json?["idempotencyKey"] as? String }, ["abcdefghijklmnop", "abcdefghijklmnop"])
        XCTAssertNotEqual(sent[0].headers["authorization"], sent[1].headers["authorization"])
    }

    func testSubmitRateLimitedRetriesAfterRetryAfterWithSameKey() async throws {
        let h = try await loadedHarness()
        var n = 0
        serve(["/v1/submit": { _ in
            n += 1
            return n == 1 ? Contract.fixture("submit-rate-limited").mockResponse() : Contract.fixture("submit-ok").mockResponse()
        }])
        let sub = FeedpulseSubmission(formId: formId, values: ["title": "t", "severity": "low"])
        let receipt = try await h.client.submit(sub)
        XCTAssertEqual(receipt.id, "0b9f1c2d-3e4f-4a5b-8c6d-7e8f9a0b1c2d")
        XCTAssertEqual(h.clock.sleeps, [30])
        XCTAssertEqual(requests("/v1/submit").map { $0.json?["idempotencyKey"] as? String }, [sub.idempotencyKey, sub.idempotencyKey])
    }

    func testSubmitAppNotRegisteredIsNotRetried() async throws {
        let h = try await loadedHarness()
        serve(["/v1/submit": { _ in Contract.fixture("submit-app-not-registered").mockResponse() }])
        do {
            try await h.client.submit(FeedpulseSubmission(formId: formId, values: ["title": "t", "severity": "low"]))
            XCTFail()
        } catch {
            XCTAssertEqual((error as? FeedpulseError)?.apiCode, .appNotRegistered)
        }
        XCTAssertEqual(requests("/v1/submit").count, 1)
    }
}
