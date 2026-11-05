import Foundation
import XCTest
@testable import Feedpulse

// MARK: - HTTP モック

struct RecordedRequest {
    var method: String
    var path: String
    var query: String?
    var headers: [String: String]   // 小文字キー
    var body: Data?

    var json: [String: Any]? { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    var pathWithQuery: String { query.map { "\(path)?\($0)" } ?? path }
}

struct MockResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data
    var networkError: URLError.Code?

    static func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> MockResponse {
        MockResponse(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
    static func failure(_ code: URLError.Code) -> MockResponse { MockResponse(status: 0, body: Data(), networkError: code) }
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((RecordedRequest) -> MockResponse)?
    nonisolated(unsafe) static var requests: [RecordedRequest] = []
    private static let lock = NSLock()

    static func reset(_ h: @escaping (RecordedRequest) -> MockResponse) {
        lock.lock(); defer { lock.unlock() }
        handler = h
        requests = []
    }

    static var recorded: [RecordedRequest] { lock.lock(); defer { lock.unlock() }; return requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k.lowercased()] = v }
        let url = request.url!
        let recorded = RecordedRequest(method: request.httpMethod ?? "GET", path: url.path, query: url.query, headers: headers, body: body)
        Self.lock.lock()
        Self.requests.append(recorded)
        let handler = Self.handler
        Self.lock.unlock()
        guard let response = handler?(recorded) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        if let code = response.networkError {
            client?.urlProtocol(self, didFailWithError: URLError(code)); return
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func makeMockSession() -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: c)
}

// MARK: - App Attest の偽物

final class FakeAppAttest: AppAttestServing, @unchecked Sendable {
    var isSupported = true
    var generatedKeys = 0
    var assertions = 0
    var keyId = "a2V5SWQ="               // contract.json の keyId（"keyId" の base64）
    var attestation = Data("attestation".utf8)  // "YXR0ZXN0YXRpb24="
    var assertion = Data("assertion".utf8)      // "YXNzZXJ0aW9u"
    var lastClientDataHash: Data?

    func generateKey() async throws -> String { generatedKeys += 1; return keyId }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { lastClientDataHash = clientDataHash; return attestation }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        assertions += 1; lastClientDataHash = clientDataHash; return assertion
    }
}

// MARK: - 時刻と待機

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var _sleeps: [TimeInterval] = []
    init(_ now: Date = Date(timeIntervalSince1970: 1_700_000_000)) { _now = now }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    var sleeps: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _sleeps }
    func advance(_ seconds: TimeInterval) { lock.lock(); _now = _now.addingTimeInterval(seconds); lock.unlock() }
    func recordSleep(_ s: TimeInterval) { lock.lock(); _sleeps.append(s); lock.unlock() }

    func environment() -> FeedpulseEnvironment {
        FeedpulseEnvironment(
            now: { self.now },
            sleep: { self.recordSleep($0) },
            random: { 0 },
            autoContext: { AutoContext(os: "iOS 17.2", locale: "ja-JP", timezone: "Asia/Tokyo") }
        )
    }
}

final class MemoryConfigStore: ConfigCacheStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: CachedConfig?
    init(_ v: CachedConfig? = nil) { value = v }
    func load() -> CachedConfig? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ cached: CachedConfig) { lock.lock(); value = cached; lock.unlock() }
}

// MARK: - 契約 fixture

struct ContractFixture {
    var name: String
    var kind: String
    var request: [String: Any]
    var response: [String: Any]

    var requestBody: Any? { request["body"] }
    var status: Int { response["status"] as! Int }
    var responseBody: Any { response["body"] as Any }
    var responseHeaders: [String: String] { (response["headers"] as? [String: String]) ?? [:] }
    var responseSchema: String? { response["schema"] as? String }
    var requestSchema: String? { request["schema"] as? String }

    func mockResponse() -> MockResponse { .json(status, responseBody, headers: responseHeaders) }
}

enum Contract {
    static func resource(_ path: String) throws -> Data {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(path)
        return try Data(contentsOf: url)
    }

    static let fixtures: [String: ContractFixture] = {
        let root = try! JSONSerialization.jsonObject(with: resource("contract.json")) as! [String: Any]
        var out: [String: ContractFixture] = [:]
        for raw in root["fixtures"] as! [[String: Any]] {
            let f = ContractFixture(name: raw["name"] as! String, kind: raw["kind"] as! String,
                                    request: raw["request"] as! [String: Any], response: raw["response"] as! [String: Any])
            out[f.name] = f
        }
        return out
    }()

    static func fixture(_ name: String) -> ContractFixture { fixtures[name]! }

    static func schema(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: resource("schemas/\(name).schema.json")) as! [String: Any]
    }

    /// body が schema に適合するか。違反の説明を返す（適合なら空）。
    static func violations(_ value: Any, schema name: String) throws -> [String] {
        var out: [String] = []
        MiniSchema.validate(value, try schema(name), path: "$", errors: &out)
        return out
    }
}

/// 契約の JSON Schema が使っている範囲だけの検証器（type / required / properties / additionalProperties / enum / const / pattern /
/// minLength / maxLength / minimum / oneOf / items）。
enum MiniSchema {
    static func validate(_ v: Any, _ s: [String: Any], path: String, errors: inout [String]) {
        if let one = s["oneOf"] as? [[String: Any]] {
            let matches = one.filter { var e: [String] = []; validate(v, $0, path: path, errors: &e); return e.isEmpty }
            if matches.count != 1 { errors.append("\(path): oneOf matched \(matches.count)") }
            return
        }
        if let c = s["const"], !same(c, v) { errors.append("\(path): const mismatch") }
        if let e = s["enum"] as? [Any], !e.contains(where: { same($0, v) }) { errors.append("\(path): not in enum (\(v))") }
        if let t = s["type"] {
            let types = (t as? [String]) ?? [t as! String]
            if !types.contains(where: { matches(v, type: $0) }) { errors.append("\(path): type \(types) expected"); return }
        }
        if let str = v as? String {
            if let p = s["pattern"] as? String, str.range(of: p, options: .regularExpression) == nil { errors.append("\(path): pattern \(p)") }
            if let m = s["minLength"] as? Int, str.count < m { errors.append("\(path): minLength") }
            if let m = s["maxLength"] as? Int, str.count > m { errors.append("\(path): maxLength") }
        }
        if let n = v as? NSNumber, !(v is Bool), let m = s["minimum"] as? Double, n.doubleValue < m { errors.append("\(path): minimum") }
        if let obj = v as? [String: Any] {
            for r in (s["required"] as? [String]) ?? [] where obj[r] == nil { errors.append("\(path): missing \(r)") }
            let props = (s["properties"] as? [String: [String: Any]]) ?? [:]
            for (k, val) in obj {
                if let ps = props[k] { validate(val, ps, path: "\(path).\(k)", errors: &errors) }
                else if let ap = s["additionalProperties"] {
                    if let b = ap as? Bool, !b { errors.append("\(path): unexpected key \(k)") }
                    else if let sub = ap as? [String: Any] { validate(val, sub, path: "\(path).\(k)", errors: &errors) }
                }
            }
        }
        if let arr = v as? [Any], let items = s["items"] as? [String: Any] {
            for (i, el) in arr.enumerated() { validate(el, items, path: "\(path)[\(i)]", errors: &errors) }
        }
    }

    private static func matches(_ v: Any, type: String) -> Bool {
        switch type {
        case "object": return v is [String: Any]
        case "array": return v is [Any]
        case "string": return v is String
        case "boolean": return (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        case "integer": return (v as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == $0.doubleValue.rounded() } ?? false
        case "number": return (v as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false
        default: return true
        }
    }

    private static func same(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = a as? NSNumber, let y = b as? NSNumber { return x == y }
        return false
    }
}
