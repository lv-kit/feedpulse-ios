import XCTest
@testable import Feedpulse

@MainActor
final class ClientTests: XCTestCase {
    let contract = ContractTests()
    var formId: String { contract.formId }

    func harness(store: ConfigCacheStore? = nil, clock: TestClock = TestClock(), maxAttempts: Int = 3) -> ContractTests.Harness {
        contract.makeHarness(maxAttempts: maxAttempts, store: store, clock: clock)
    }

    func count(_ path: String) -> Int { contract.requests(path).count }

    // MARK: セッションのキャッシュ

    func testSessionIsCachedUntilNearExpiry() async throws {
        let h = harness()
        contract.serve()
        try await h.client.refresh(force: true)
        try await h.client.refresh(force: true)
        XCTAssertEqual(count("/v1/native/session"), 1)
        XCTAssertEqual(count("/v1/config"), 2)

        h.clock.advance(860)   // 期限(900)の 40 秒前: まだ有効
        try await h.client.refresh(force: true)
        XCTAssertEqual(count("/v1/native/session"), 1)

        h.clock.advance(20)    // 期限の 20 秒前（余裕 30 秒を切る）→ 事前に更新
        try await h.client.refresh(force: true)
        XCTAssertEqual(count("/v1/native/session"), 2)
    }

    func testConcurrentCallsShareOneSessionAcquisition() async throws {
        let h = harness()
        contract.serve()
        _ = try await h.client.refresh()
        let client = h.client
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { try await client.refresh(force: true) }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(count("/v1/native/session"), 1)
    }

    // MARK: config のキャッシュ

    func testFreshCacheSkipsNetworkAndMaxAgeExpires() async throws {
        let h = harness()
        contract.serve()
        try await h.client.refresh()
        try await h.client.refresh()
        XCTAssertEqual(count("/v1/config"), 1)   // cache-control: max-age=60 の間は通信しない
        h.clock.advance(61)
        try await h.client.refresh()
        XCTAssertEqual(count("/v1/config"), 2)
    }

    func testFailureFallsBackToPreviousValue() async throws {
        let h = harness()
        contract.serve()
        try await h.client.refresh()
        contract.serve(["/v1/config": { _ in .failure(.notConnectedToInternet) }])
        h.clock.advance(120)
        let forms = try await h.client.refresh()
        XCTAssertEqual(forms.first?.version, 3)
        XCTAssertTrue(h.client.isStale)
        XCTAssertNotNil(h.client.lastRefreshError)
        XCTAssertEqual(h.client.forms.count, 1)
        // 回復したら stale が消える
        contract.serve()
        try await h.client.refresh()
        XCTAssertFalse(h.client.isStale)
        XCTAssertNil(h.client.lastRefreshError)
    }

    func testFailureWithoutCacheThrows() async {
        let h = harness(maxAttempts: 1)
        contract.serve(["/v1/config": { _ in .failure(.timedOut) }])
        do { try await h.client.refresh(); XCTFail() } catch {
            guard case .network = error as? FeedpulseError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(h.client.lastRefreshError.map { _ in true }, true)
    }

    func testPersistedCacheIsUsedAfterRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = URL(string: "https://ingest.example.test")!
        let store = FileConfigCacheStore(directory: dir, baseURL: url, publicKey: "pk_example")
        let first = harness(store: store)
        contract.serve()
        try await first.client.refresh()

        // 再起動相当: 新しいエンジンが同じディスクから読む。通信は失敗する。
        let second = harness(store: FileConfigCacheStore(directory: dir, baseURL: url, publicKey: "pk_example"))
        contract.serve(["/v1/native/challenge": { _ in .failure(.notConnectedToInternet) }])
        let cached = await second.engine.cachedConfig
        XCTAssertEqual(cached?.forms.first?.id, formId)
        XCTAssertNotEqual(FileConfigCacheStore(directory: dir, baseURL: url, publicKey: "pk_other").fileURL, store.fileURL)
        second.clock.advance(1000)
        let forms = try await second.client.refresh()   // 古い & 通信失敗 → 前回値
        XCTAssertEqual(forms.first?.id, formId)
        XCTAssertTrue(second.client.isStale)
    }

    func testCorruptCacheFileIsIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileConfigCacheStore(directory: dir, baseURL: URL(string: "https://x.test")!, publicKey: "pk_a")
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertNil(store.load())
    }

    func testCacheControlParsing() {
        XCTAssertEqual(CacheControl.maxAge("private, max-age=60"), 60)
        XCTAssertEqual(CacheControl.maxAge("max-age=0"), 0)
        XCTAssertEqual(CacheControl.maxAge(nil), 60)
        XCTAssertEqual(CacheControl.maxAge("no-store"), 60)
    }

    func testUnknownBlockTypeSurvivesRoundTrip() throws {
        let json = #"{"widget":{"a":[1,"x",null,true]},"forms":[{"id":"i","slug":"s","name":"n","type":"future","version":1,"definition":{"blocks":[{"id":"b","type":"hologram","label":"l","required":false}]}}]}"#
        let config = try JSONDecoder().decode(FeedpulseConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.forms[0].definition.blocks[0].type, .unknown("hologram"))
        let again = try JSONDecoder().decode(FeedpulseConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(again, config)
        XCTAssertTrue(config.forms[0].validate(["b": "anything"]).isValid)
    }

    // MARK: 再送

    func testNetworkErrorsRetryWithBackoffAndSameKey() async throws {
        let h = harness()
        contract.serve()
        try await h.client.refresh()
        var n = 0
        contract.serve(["/v1/submit": { _ in
            n += 1
            return n <= 2 ? .failure(.timedOut) : Contract.fixture("submit-ok").mockResponse()
        }])
        let sub = FeedpulseSubmission(formId: formId, values: ["title": "t", "severity": "low"])
        _ = try await h.client.submit(sub)
        XCTAssertEqual(count("/v1/submit"), 3)
        XCTAssertEqual(h.clock.sleeps, [0.25, 0.5])   // 0.5 * 2^(n-1) * (0.5 + random(=0) * 0.5)
        XCTAssertEqual(Set(contract.requests("/v1/submit").compactMap { $0.json?["idempotencyKey"] as? String }), [sub.idempotencyKey])
    }

    func testServerErrorExhaustsAttempts() async throws {
        let h = harness()
        contract.serve()
        try await h.client.refresh()
        contract.serve(["/v1/submit": { _ in .json(503, ["error": "internal"]) }])
        do {
            try await h.client.submit(FeedpulseSubmission(formId: formId, values: ["title": "t", "severity": "low"]))
            XCTFail()
        } catch let error as FeedpulseError {
            XCTAssertEqual(error.apiCode, .internal)
            XCTAssertTrue(error.isRetryable)
        }
        XCTAssertEqual(count("/v1/submit"), 3)
    }

    func testClientErrorsAreNotRetried() async throws {
        let h = harness()
        contract.serve()
        try await h.client.refresh()
        contract.serve(["/v1/submit": { _ in .json(413, ["error": "payload_too_large"]) }])
        do {
            try await h.client.submit(FeedpulseSubmission(formId: formId, values: ["title": "t", "severity": "low"]))
            XCTFail()
        } catch {
            XCTAssertEqual((error as? FeedpulseError)?.apiCode, .payloadTooLarge)
            XCTAssertFalse((error as? FeedpulseError)?.isRetryable ?? true)
        }
        XCTAssertEqual(count("/v1/submit"), 1)
    }

    func testNonContractErrorBodyBecomesInvalidResponse() async throws {
        let h = harness()
        contract.serve(["/v1/config": { _ in MockResponse(status: 502, body: Data("<html>".utf8)) }])
        do { try await h.client.refresh(); XCTFail() } catch {
            XCTAssertEqual(error as? FeedpulseError, .invalidResponse(status: 502))
        }
    }

    // MARK: submit の前処理

    func testUnknownFormLoadsConfigThenThrows() async {
        let h = harness()
        contract.serve()
        do {
            try await h.client.submit(FeedpulseSubmission(formId: "nope", values: [:]))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? FeedpulseError, .unknownForm("nope"))
        }
        XCTAssertEqual(count("/v1/config"), 1)
        XCTAssertEqual(count("/v1/submit"), 0)
    }

    func testSubmitLoadsConfigOnDemand() async throws {
        let h = harness()
        contract.serve()
        try await h.client.submit(FeedpulseSubmission(formId: formId, values: ["title": "t", "severity": "low"]))
        XCTAssertEqual(count("/v1/config"), 1)
        XCTAssertEqual(count("/v1/submit"), 1)
        XCTAssertFalse(h.client.isSubmitting)
    }

    func testInvalidIdempotencyKeyRejectedLocally() async {
        let h = harness()
        contract.serve()
        do {
            try await h.client.submit(FeedpulseSubmission(formId: formId, values: [:], idempotencyKey: "short"))
            XCTFail()
        } catch {
            guard case .invalidArgument = error as? FeedpulseError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
    }

    func testGeneratedIdempotencyKeysMatchContractPatternAndAreUnique() {
        let keys = (0..<200).map { _ in FeedpulseSubmission.generateIdempotencyKey() }
        XCTAssertEqual(Set(keys).count, 200)
        for k in keys {
            XCTAssertTrue(FeedpulseSubmission.isValidIdempotencyKey(k), k)
            XCTAssertEqual(k.range(of: "^[A-Za-z0-9_-]{16,64}$", options: .regularExpression) != nil, true)
        }
        XCTAssertFalse(FeedpulseSubmission.isValidIdempotencyKey("has space 12345678"))
        XCTAssertFalse(FeedpulseSubmission.isValidIdempotencyKey(String(repeating: "a", count: 65)))
    }

    func testAutoContextCanBeDisabled() async throws {
        let attest = FakeAppAttest()
        let config = FeedpulseConfiguration(
            publicKey: "pk_example", baseURL: URL(string: "https://ingest.example.test")!, appId: "com.example.app",
            attestation: AppAttestProvider(service: attest, keyStore: InMemoryKeyStore()),
            urlSession: makeMockSession(), sendsAutoContext: false)
        let client = FeedpulseClient(engine: FeedpulseEngine(config: config, env: TestClock().environment(), store: MemoryConfigStore()))
        contract.serve()
        try await client.submit(FeedpulseSubmission(formId: formId, values: ["title": "t", "severity": "low"]))
        XCTAssertNil(contract.requests("/v1/submit")[0].json?["context"])
    }

    func testDevInsecureProviderSendsDevPayload() async throws {
        let config = FeedpulseConfiguration(
            publicKey: "pk_example", baseURL: URL(string: "https://ingest.example.test")!, appId: "com.example.app",
            attestation: DevInsecureAttestationProvider(), urlSession: makeMockSession())
        let client = FeedpulseClient(engine: FeedpulseEngine(config: config, env: TestClock().environment(), store: MemoryConfigStore()))
        contract.serve()
        try await client.refresh()
        let attestation = contract.requests("/v1/native/session")[0].json?["attestation"] as? [String: String]
        XCTAssertEqual(attestation, ["type": "dev_insecure"])
        XCTAssertEqual(try Contract.violations(contract.requests("/v1/native/session")[0].json!, schema: "native-session-request"), [])
    }

    func testErrorCodeRoundTrip() {
        for raw in ["invalid_json", "challenge_expired", "invalid_idempotency_key", "project_read_only", "internal", "not_found"] {
            XCTAssertEqual(FeedpulseErrorCode(rawValue: raw).rawValue, raw)
        }
        XCTAssertEqual(FeedpulseErrorCode(rawValue: "brand_new"), .unknown("brand_new"))
        XCTAssertEqual(FeedpulseErrorCode(rawValue: "brand_new").rawValue, "brand_new")
    }
}

final class ValidatorTests: XCTestCase {
    func block(_ type: FeedpulseBlockType, required: Bool = false, maxLength: Int? = nil, min: Double? = nil, max: Double? = nil,
               options: [String]? = nil, maxFiles: Int? = nil) -> FeedpulseBlock {
        FeedpulseBlock(id: "b", type: type, label: "L", required: required, maxLength: maxLength, min: min, max: max,
                       options: options?.map { FeedpulseOption(value: $0, label: $0) }, maxFiles: maxFiles)
    }

    func run(_ b: FeedpulseBlock, _ v: FeedpulseValue?) -> FeedpulseValidationResult {
        FormValidator.validate(blocks: [b], values: v.map { ["b": $0] } ?? [:])
    }

    func testRequiredAndEmpty() {
        XCTAssertEqual(run(block(.shortText, required: true), nil).errors["b"], .required)
        XCTAssertEqual(run(block(.shortText, required: true), "").errors["b"], .required)
        XCTAssertEqual(run(block(.shortText, required: true), "  \t ").errors["b"], .required)
        XCTAssertEqual(run(block(.checkbox, required: true, options: ["a"]), []).errors["b"], .required)
        XCTAssertTrue(run(block(.shortText), nil).isValid)
        XCTAssertTrue(run(block(.shortText), "   ").cleaned.isEmpty)
    }

    func testTextNormalizationAndLimits() {
        XCTAssertEqual(run(block(.shortText), " a\u{0}b\nc ").cleaned["b"], "abc")
        XCTAssertEqual(run(block(.longText), " a\nb\u{1} ").cleaned["b"], "a\nb")
        XCTAssertEqual(run(block(.shortText, maxLength: 3), "abcd").errors["b"], .tooLong)
        XCTAssertTrue(run(block(.shortText, maxLength: 3), "abc").isValid)
        XCTAssertEqual(run(block(.shortText), .text(String(repeating: "a", count: 201))).errors["b"], .tooLong)
        XCTAssertTrue(run(block(.longText), .text(String(repeating: "a", count: 5000))).isValid)
        XCTAssertEqual(run(block(.longText), .text(String(repeating: "a", count: 5001))).errors["b"], .tooLong)
        // UTF-16 長（JS の length と同じ）: 😀 は 2
        XCTAssertEqual(run(block(.shortText, maxLength: 1), "😀").errors["b"], .tooLong)
        XCTAssertEqual(run(block(.shortText), 3).errors["b"], .type)
    }

    func testEmail() {
        XCTAssertTrue(run(block(.email), " a@b.co ").isValid)
        XCTAssertEqual(run(block(.email), "a@b").errors["b"], .invalidEmail)
        XCTAssertEqual(run(block(.email), "a b@c.d").errors["b"], .invalidEmail)
        XCTAssertEqual(run(block(.email), .text(String(repeating: "a", count: 250) + "@b.cd")).errors["b"], .invalidEmail)
    }

    func testNumberAndRating() {
        XCTAssertEqual(run(block(.number, min: 1, max: 5), 6).errors["b"], .outOfRange)
        XCTAssertEqual(run(block(.number, min: 1, max: 5), 0.5).errors["b"], .outOfRange)
        XCTAssertTrue(run(block(.number, min: 1, max: 5), 2.5).isValid)
        XCTAssertEqual(run(block(.number), "1").errors["b"], .type)
        XCTAssertEqual(run(block(.number), .number(.nan)).errors["b"], .type)
        XCTAssertEqual(run(block(.rating, max: 5), 0).errors["b"], .outOfRange)
        XCTAssertEqual(run(block(.rating, max: 5), 6).errors["b"], .outOfRange)
        XCTAssertEqual(run(block(.rating, max: 5), 2.5).errors["b"], .type)
        XCTAssertTrue(run(block(.rating, max: 5), 5).isValid)
    }

    func testChoices() {
        XCTAssertEqual(run(block(.radio, options: ["a", "b"]), "c").errors["b"], .invalidOption)
        XCTAssertTrue(run(block(.select, options: ["a"]), "a").isValid)
        XCTAssertEqual(run(block(.checkbox, options: ["a", "b"]), ["a", "x"]).errors["b"], .invalidOption)
        XCTAssertEqual(run(block(.checkbox, options: ["a", "b"]), ["a", "a", "b"]).cleaned["b"], ["a", "b"])   // 重複除去
        XCTAssertEqual(run(block(.checkbox, options: ["a"]), "a").errors["b"], .type)
    }

    func testUploads() {
        let u1 = "6f1d2c3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f", u2 = "0b9f1c2d-3e4f-4a5b-8c6d-7e8f9a0b1c2d"
        XCTAssertTrue(run(block(.image, maxFiles: 2), [.list([u1, u2])].first).isValid)
        XCTAssertEqual(run(block(.image, maxFiles: 1), .list([u1, u2])).errors["b"], .tooManyFiles)
        XCTAssertEqual(run(block(.file, maxFiles: 2), .list(["nope"])).errors["b"], .invalidUpload)
        XCTAssertEqual(run(block(.file, maxFiles: 2), .list([u1, u1])).errors["b"], .invalidUpload)
    }

    func testMultipleErrorsAndOmittedUnknownKeys() {
        let blocks = [block(.shortText, required: true), FeedpulseBlock(id: "c", type: .email, label: "", required: true)]
        let r = FormValidator.validate(blocks: blocks, values: ["c": "bad", "ignored": "x"])
        XCTAssertEqual(r.errors, ["b": .required, "c": .invalidEmail])
        XCTAssertNil(r.cleaned["ignored"])
    }
}

@MainActor
final class ReviewFixTests: XCTestCase {
    let contract = ContractTests()

    func testRetryAfterSupportsHttpDatesAndRejectsInvalidValues() {
        let bodies = [Data(), Data("{\"error\":\"rate_limited\"}".utf8)]
        for body in bodies {
            func decode(_ value: String) -> FeedpulseAPIError? {
                let response = HTTPResponse(status: 429, headers: [
                    "date": "Sun, 06 Nov 1994 08:49:37 GMT",
                    "retry-after": value,
                ], body: body)
                if case .api(let error) = APIErrorDecoder.decode(response) { return error }
                return nil
            }
            XCTAssertEqual(decode("Sun, 06 Nov 1994 08:50:37 GMT")?.retryAfter, 60)
            XCTAssertEqual(decode("Sunday, 06-Nov-94 08:50:37 GMT")?.retryAfter, 60)
            XCTAssertEqual(decode("Sun Nov  6 08:50:37 1994")?.retryAfter, 60)
            XCTAssertEqual(decode("Sun, 06 Nov 1994 08:48:37 GMT")?.retryAfter, 0)
            XCTAssertEqual(decode(" 30 ")?.retryAfter, 30)
            for value in ["-1", "1.5", "NaN", "inf", "invalid"] {
                XCTAssertNil(decode(value)?.retryAfter)
            }
        }
    }

    func testNonJSONRateLimitIsRetriedWithRetryAfter() async throws {
        let h = contract.makeHarness()
        contract.serve()
        try await h.client.refresh()
        contract.serve(["/v1/submit": { _ in
            MockResponse(status: 429, headers: ["Retry-After": "2"], body: Data("<html>busy</html>".utf8))
        }])
        do {
            try await h.client.submit(FeedpulseSubmission(formId: contract.formId, values: ["title": "t", "severity": "low"]))
            XCTFail()
        } catch let error as FeedpulseError {
            guard case .api(let api) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(api.code, .rateLimited)
            XCTAssertEqual(api.retryAfter, 2)
            XCTAssertTrue(error.isRetryable)
        }
        XCTAssertEqual(contract.requests("/v1/submit").count, 3)
    }

    func testQuotaExceededIsNotRetried() async throws {
        let h = contract.makeHarness()
        contract.serve()
        try await h.client.refresh()
        contract.serve(["/v1/submit": { _ in .json(429, ["error": "quota_exceeded"]) }])
        do { try await h.client.submit(FeedpulseSubmission(formId: contract.formId, values: ["title": "t", "severity": "low"])); XCTFail() }
        catch { XCTAssertEqual((error as? FeedpulseError)?.apiCode, .quotaExceeded) }
        XCTAssertEqual(contract.requests("/v1/submit").count, 1)
    }

    func testNewlyPublishedFormRefetchesDespiteFreshCache() async throws {
        let h = contract.makeHarness()
        contract.serve()
        try await h.client.refresh()
        contract.serve(["/v1/config": { _ in
            var body = Contract.fixture("config-ok").responseBody as! [String: Any]
            var forms = body["forms"] as! [[String: Any]]
            var second = forms[0]; second["id"] = "11111111-2222-4333-8444-555555555555"; forms.append(second)
            body["forms"] = forms
            return .json(200, body, headers: ["cache-control": "private, max-age=60"])
        }])
        try await h.client.submit(FeedpulseSubmission(formId: "11111111-2222-4333-8444-555555555555", values: ["title": "t", "severity": "low"]))
        XCTAssertEqual(contract.requests("/v1/config").count, 1)
    }

    func testInvalidStoredKeyIsRecreatedInSameCall() async throws {
        final class Failing: AppAttestServing, @unchecked Sendable {
            var isSupported = true
            func generateKey() async throws -> String { "bmV3S2V5" }
            func attestKey(_ k: String, clientDataHash: Data) async throws -> Data { Data("a".utf8) }
            func generateAssertion(_ k: String, clientDataHash: Data) async throws -> Data { throw NSError(domain: "DCErrorDomain", code: 3) }
        }
        let store = InMemoryKeyStore("b2xk")
        let p = AppAttestProvider(service: Failing(), keyStore: store)
        let payload = try await p.payload(forChallenge: String(repeating: "A", count: 48))
        XCTAssertEqual(payload, .attestation(keyId: "bmV3S2V5", attestation: "YQ=="))
        XCTAssertNil(store.load())
    }

    func testJSWhitespaceTrim() {
        let b = FeedpulseBlock(id: "b", type: .shortText, label: "", required: true)
        XCTAssertEqual(FormValidator.validate(blocks: [b], values: ["b": "\u{FEFF}"]).errors["b"], .required)
        XCTAssertEqual(FormValidator.validate(blocks: [b], values: ["b": "\u{FEFF}x\u{3000}"]).cleaned["b"], "x")
    }
}
