#if canImport(UIKit)
import UIKit
import WebKit

/// タップ座標から `FeedpulseTarget` を組み立てる。UI を持たず、スクリーンショットも撮らない。
///
/// 取得しないもの: `UITextField` / `UITextView` の値、`isSecureTextEntry` の入力に紐づく文言。
/// 読むのは `accessibilityIdentifier` / `accessibilityLabel` / クラス名 / frame だけ。
enum TargetResolver {
    /// `window` 内の `point`（window 座標）にある要素を特定する。
    static func resolve(
        in window: UIWindow,
        at point: CGPoint,
        screenName: String?,
        labelLimit: Int = FeedpulseTargetLimits.defaultLabel
    ) -> FeedpulseTarget {
        let hit = window.hitTest(point, with: nil) ?? window

        // WKWebView の中身はネイティブから選べない。WebView 全体を対象にする。
        let webView = ancestors(of: hit).first { $0 is WKWebView } as? WKWebView
        let leaf: UIView = webView ?? hit

        let explicit = explicitSubject(leaf: leaf, in: window, at: point)
        let subject = explicit?.view ?? leaf

        var target = FeedpulseTarget(platform: .ios)
        target.id = explicit?.id
        target.path = path(of: subject, in: window)
        target.rect = rect(of: subject, in: window)
        target.label = explicit?.label ?? safeLabel(of: subject)
        target.screen = webView.flatMap { urlWithoutQuery($0.url) }
            ?? screenName
            ?? topViewControllerName(of: window)
        return TargetSanitizer.sanitize(target, labelLimit: labelLimit)
    }

    // MARK: 明示 ID（自動取得より優先）

    private struct Explicit {
        let view: UIView
        let id: String
        let label: String?
    }

    /// 明示 ID の候補は 2 種類。
    /// - 祖先の `accessibilityIdentifier`（UIKit）
    /// - タップ座標を含む `.feedpulseId` の目印（SwiftUI）
    /// 面積が最小（最も具体的）なものを選び、同面積なら目印を優先する。
    private static func explicitSubject(leaf: UIView, in window: UIWindow, at point: CGPoint) -> Explicit? {
        var candidates: [(Explicit, CGFloat, Int)] = []

        if let view = ancestors(of: leaf).first(where: { !($0.accessibilityIdentifier ?? "").isEmpty }),
           let id = view.accessibilityIdentifier {
            let label = view is FeedpulseIdMarkerView ? nil : safeLabel(of: view)
            candidates.append((Explicit(view: view, id: id, label: label), area(of: view, in: window), 1))
        }
        for marker in markers(in: window) {
            let frame = marker.convert(marker.bounds, to: window)
            guard !marker.isHidden, frame.contains(point), !marker.feedpulseId.isEmpty else { continue }
            candidates.append((Explicit(view: marker, id: marker.feedpulseId, label: marker.feedpulseLabel),
                               frame.width * frame.height, 0))
        }
        return candidates.min { ($0.1, $0.2) < ($1.1, $1.2) }?.0
    }

    private static func markers(in root: UIView) -> [FeedpulseIdMarkerView] {
        var found: [FeedpulseIdMarkerView] = []
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let marker = view as? FeedpulseIdMarkerView { found.append(marker) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    // MARK: ラベル（秘匿入力は取らない）

    /// `accessibilityLabel` の生の値。入力欄・秘匿入力では値が漏れないよう落とす。
    static func safeLabel(of view: UIView) -> String? {
        if isSecureInput(view) { return nil }
        guard let label = view.accessibilityLabel, !label.isEmpty else { return nil }
        // 入力欄の label が現在の入力値と一致する場合は値そのものなので採らない。
        if let field = view as? UITextField, field.text == label { return nil }
        if let textView = view as? UITextView, textView.text == label { return nil }
        return label
    }

    private static func isSecureInput(_ view: UIView) -> Bool {
        if let field = view as? UITextField, field.isSecureTextEntry { return true }
        if let textView = view as? UITextView, textView.isSecureTextEntry { return true }
        if let traits = view as? UITextInputTraits, traits.isSecureTextEntry == true { return true }
        return false
    }

    // MARK: パス・rect・画面名

    private static func ancestors(of view: UIView) -> [UIView] {
        var chain: [UIView] = []
        var current: UIView? = view
        while let v = current {
            chain.append(v)
            current = v.superview
        }
        return chain
    }

    /// `UIWindow>UIView[0]>UIButton[2]` 形式（window から対象まで）。クラス名と兄弟内の位置のみ。
    static func path(of view: UIView, in window: UIWindow) -> String {
        var parts: [String] = []
        var current: UIView? = view
        while let v = current, v !== window {
            let index = v.superview?.subviews.firstIndex(of: v) ?? 0
            parts.append("\(String(describing: type(of: v)))[\(index)]")
            current = v.superview
        }
        parts.append(String(describing: type(of: window)))
        return parts.reversed().joined(separator: ">")
    }

    private static func rect(of view: UIView, in window: UIWindow) -> FeedpulseTarget.Rect {
        let f = view.convert(view.bounds, to: window)
        return .init(x: Double(f.origin.x), y: Double(f.origin.y), w: Double(f.width), h: Double(f.height))
    }

    private static func area(of view: UIView, in window: UIWindow) -> CGFloat {
        let f = view.convert(view.bounds, to: window)
        return f.width * f.height
    }

    /// クエリとフラグメントは落とす（トークン等が混ざりうるため）。
    private static func urlWithoutQuery(_ url: URL?) -> String? {
        guard let url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        return c.string
    }

    /// 最前面の `UIViewController` の型名。
    static func topViewControllerName(of window: UIWindow) -> String? {
        guard var vc = window.rootViewController else { return nil }
        while true {
            if let presented = vc.presentedViewController {
                vc = presented
            } else if let nav = vc as? UINavigationController, let top = nav.visibleViewController {
                if top === vc { break }
                vc = top
            } else if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
                vc = selected
            } else {
                break
            }
        }
        return String(describing: type(of: vc))
    }
}
#endif
