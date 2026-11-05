import Foundation

struct HTTPResponse {
    var status: Int
    /// キーは小文字。
    var headers: [String: String]
    var body: Data

    var isSuccess: Bool { (200..<300).contains(status) }
}

/// URLSession の薄いラッパー。Origin は付けない（ネイティブ経路の条件）。
struct Transport: @unchecked Sendable {
    let session: URLSession
    let baseURL: URL
    let timeout: TimeInterval

    func send(method: String, path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> HTTPResponse {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw FeedpulseError.invalidArgument("invalid URL: \(path)")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FeedpulseError.invalidResponse(status: 0) }
            var h: [String: String] = [:]
            for (k, v) in http.allHeaderFields { h[String(describing: k).lowercased()] = String(describing: v) }
            return HTTPResponse(status: http.statusCode, headers: h, body: data)
        } catch let error as FeedpulseError {
            throw error
        } catch is CancellationError {
            throw FeedpulseError.cancelled
        } catch let error as URLError {
            if error.code == .cancelled { throw FeedpulseError.cancelled }
            throw FeedpulseError.network(error.localizedDescription)
        } catch {
            throw FeedpulseError.network(error.localizedDescription)
        }
    }
}

enum APIErrorDecoder {
    private struct Body: Decodable {
        var error: String?
        var fields: [String: String]?
        var code: String?
    }

    /// 非 2xx 応答を契約のエラーに変換する。本文が契約の形でなければ `invalidResponse`。
    static func decode(_ r: HTTPResponse) -> FeedpulseError {
        guard let body = try? JSONDecoder().decode(Body.self, from: r.body), let code = body.error else {
            return .invalidResponse(status: r.status)
        }
        var fields: [String: FeedpulseFieldError] = [:]
        for (k, v) in body.fields ?? [:] {
            if let f = FeedpulseFieldError(rawValue: v) { fields[k] = f }
        }
        return .api(FeedpulseAPIError(
            status: r.status,
            code: FeedpulseErrorCode(rawValue: code),
            fields: fields,
            identityFailure: body.code.map(FeedpulseIdentityFailure.init(rawValue:)),
            retryAfter: r.headers["retry-after"].flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        ))
    }
}

/// 再送の方針。ネットワークエラー・429・5xx だけを再送する。
struct Retrier {
    var maxAttempts: Int
    var maxRetryAfterWait: TimeInterval
    var baseDelay: TimeInterval = 0.5
    var maxDelay: TimeInterval = 8
    var env: FeedpulseEnvironment

    func run<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let error as FeedpulseError where error.isRetryable && attempt < maxAttempts {
                var delay: TimeInterval
                if case .api(let e) = error, let retryAfter = e.retryAfter {
                    // サーバーの指示を尊重する。長すぎるなら待たずに呼び出し側へ返す。
                    if retryAfter > maxRetryAfterWait { throw error }
                    delay = retryAfter
                } else {
                    let exp = min(maxDelay, baseDelay * pow(2, Double(attempt - 1)))
                    delay = exp * (0.5 + env.random() * 0.5)
                }
                do { try await env.sleep(delay) } catch { throw FeedpulseError.cancelled }
                attempt += 1
            }
        }
    }
}
