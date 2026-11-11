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

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func retryAfter(_ headers: [String: String]) -> TimeInterval? {
        guard let raw = headers["retry-after"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let seconds = TimeInterval(raw) {
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        }
        guard let deadline = httpDate(raw) else { return nil }
        let reference = headers["date"].flatMap(httpDate) ?? Date()
        return max(0, deadline.timeIntervalSince(reference))
    }

    /// 非 2xx 応答を契約のエラーに変換する。本文が契約の形でなければ `invalidResponse`。
    static func decode(_ r: HTTPResponse) -> FeedpulseError {
        guard let body = try? JSONDecoder().decode(Body.self, from: r.body), let code = body.error else {
            if r.status == 429 {
                return .api(FeedpulseAPIError(
                    status: r.status,
                    code: .rateLimited,
                    retryAfter: retryAfter(r.headers)
                ))
            }
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
            retryAfter: retryAfter(r.headers)
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
