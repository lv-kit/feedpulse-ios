import Foundation

/// 画面上の「該当箇所」。`context.auto.target`（feedpulse-web #106）の形に一致する。
///
/// SDK はヘッドレス。この値を顧客のフォームが submit に載せる。
public struct FeedpulseTarget: Codable, Equatable, Sendable {
    public enum Platform: String, Codable, Sendable {
        case web
        case ios
        case android
        case flutter
        case reactNative = "react-native"
    }

    public struct Rect: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double

        public init(x: Double, y: Double, w: Double, h: Double) {
            self.x = x
            self.y = y
            self.w = w
            self.h = h
        }
    }

    /// 既定は `.ios`。React Native ブリッジは `.reactNative` に差し替える。
    public var platform: Platform
    /// 画面名（`UIViewController` の型名、または顧客が渡した名前）。WebView 上のタップは URL。
    public var screen: String?
    /// 明示 ID（優先）。`accessibilityIdentifier` または `.feedpulseId(...)`。
    public var id: String?
    /// 自動取得したビュー階層パス（補助）。
    public var path: String?
    /// ウィンドウ座標系の frame（pt）。
    public var rect: Rect?
    /// accessibility label の先頭 N 文字。
    public var label: String?

    public init(
        platform: Platform = .ios,
        screen: String? = nil,
        id: String? = nil,
        path: String? = nil,
        rect: Rect? = nil,
        label: String? = nil
    ) {
        self.platform = platform
        self.screen = screen
        self.id = id
        self.path = path
        self.rect = rect
        self.label = label
    }

    /// JSON オブジェクト（`[String: Any]`）。RN などブリッジ用。nil のキーは含めない。
    public var jsonObject: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ["platform": platform.rawValue] }
        return object
    }

    /// JSON 文字列。キー順は固定。
    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{\"platform\":\"\(platform.rawValue)\"}"
        }
        return text
    }
}

// MARK: - 上限と正規化（ingest の検証と同じ値で切る）

public enum FeedpulseTargetLimits {
    public static let id = 200
    public static let screen = 200
    public static let path = 512
    public static let defaultLabel = 100
    public static let maxLabel = 200
}

enum TargetSanitizer {
    /// 制御文字を除去し、前後空白を落とし、UTF-16 長で `limit` 以内に切る。空は nil。
    static func text(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            $0.properties.generalCategory != .control
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, limit > 0 else { return nil }
        return truncate(cleaned, limit: limit)
    }

    /// 先頭から `limit`（UTF-16）以内。文字（grapheme）の途中では切らない。
    static func truncate(_ text: String, limit: Int) -> String {
        var units = 0
        var out = ""
        for ch in text {
            let n = String(ch).utf16.count
            if units + n > limit { break }
            units += n
            out.append(ch)
        }
        return out
    }

    /// 末尾（最も深い要素）を残して切る。切ったときは `…>` を前置する。
    static func tail(_ text: String, limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        let prefix = "…>"
        var out: [Character] = []
        var units = prefix.utf16.count
        for ch in text.reversed() {
            let n = String(ch).utf16.count
            if units + n > limit { break }
            units += n
            out.append(ch)
        }
        return prefix + String(out.reversed())
    }

    static func rect(_ r: FeedpulseTarget.Rect?) -> FeedpulseTarget.Rect? {
        guard let r, [r.x, r.y, r.w, r.h].allSatisfy({ $0.isFinite }), r.w >= 0, r.h >= 0 else { return nil }
        return .init(x: r.x.rounded(), y: r.y.rounded(), w: r.w.rounded(), h: r.h.rounded())
    }

    /// 全フィールドを上限内に正規化する。
    static func sanitize(_ t: FeedpulseTarget, labelLimit: Int = FeedpulseTargetLimits.defaultLabel) -> FeedpulseTarget {
        var out = t
        out.screen = text(t.screen, limit: FeedpulseTargetLimits.screen)
        out.id = text(t.id, limit: FeedpulseTargetLimits.id)
        out.path = t.path.flatMap { raw in
            let cleaned = text(raw, limit: .max)
            return cleaned.map { tail($0, limit: FeedpulseTargetLimits.path) }
        }
        out.rect = rect(t.rect)
        out.label = text(t.label, limit: min(max(labelLimit, 0), FeedpulseTargetLimits.maxLabel))
        return out
    }
}
