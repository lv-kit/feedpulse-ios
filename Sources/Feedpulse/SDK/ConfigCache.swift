import Foundation
import CryptoKit

/// 取得済みの項目定義。`fetchedAt` と `ttl` で鮮度を判定する。
struct CachedConfig: Codable, Equatable, Sendable {
    var config: FeedpulseConfig
    var fetchedAt: Date
    /// `Cache-Control: max-age`（秒）。無ければ 60。
    var ttl: TimeInterval
}

protocol ConfigCacheStore: Sendable {
    func load() -> CachedConfig?
    func save(_ cached: CachedConfig)
}

/// JSON ファイルに保存する。壊れていたら読み飛ばし、書けなければ黙って諦める（キャッシュは必須ではない）。
struct FileConfigCacheStore: ConfigCacheStore {
    let fileURL: URL

    init(directory: URL?, baseURL: URL, publicKey: String) {
        let dir = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let digest = SHA256.hash(data: Data("\(baseURL.absoluteString)|\(publicKey)".utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        fileURL = dir.appendingPathComponent("Feedpulse", isDirectory: true).appendingPathComponent("config-\(name).json")
    }

    func load() -> CachedConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CachedConfig.self, from: data)
    }

    func save(_ cached: CachedConfig) {
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum CacheControl {
    static let defaultTTL: TimeInterval = 60

    static func maxAge(_ header: String?) -> TimeInterval {
        guard let header else { return defaultTTL }
        for part in header.split(separator: ",") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "max-age", let n = TimeInterval(kv[1]) { return max(0, n) }
        }
        return defaultTTL
    }
}
