#if canImport(UIKit)
import UIKit

public enum FeedpulsePickError: Error, Equatable {
    /// `cancel()` などで選択が中止された。
    case cancelled
    /// 前面のウィンドウシーンが無い。
    case noActiveScene
    /// すでに別のピッカーが動いている。
    case alreadyActive
}

/// 実行中のピッカーへのハンドル。
@MainActor
public final class FeedpulsePickerSession {
    fileprivate var onCancel: (() -> Void)?
    public private(set) var isActive = true

    /// 選択を中止する。完了ハンドラには `.cancelled` が返る。
    public func cancel() { onCancel?() }

    fileprivate func finish() {
        isActive = false
        onCancel = nil
    }
}

/// 全面の透明な `UIWindow`。UI は出さず、次の 1 タップだけを受ける。
@MainActor
final class PickerOverlay {
    private let window: UIWindow
    private var handler: ((CGPoint) -> Void)?

    init(scene: UIWindowScene, onTap: @escaping (CGPoint) -> Void) {
        handler = onTap
        window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let vc = UIViewController()
        let catcher = UIView()
        catcher.backgroundColor = .clear
        let tap = UITapGestureRecognizer()
        catcher.addGestureRecognizer(tap)
        vc.view = catcher
        window.rootViewController = vc
        tap.addTarget(self, action: #selector(tapped(_:)))
        window.isHidden = false
    }

    var overlayWindow: UIWindow { window }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: window)
        handler?(point)
    }

    func dismiss() {
        handler = nil
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// 公開 API の入口。
public enum Feedpulse {
    @MainActor private static var activeSession: FeedpulsePickerSession?

    /// 画面に透明オーバーレイを出し、次のタップで要素を特定する。
    ///
    /// - Parameters:
    ///   - screenName: 画面名。省略時は最前面の `UIViewController` の型名。
    ///   - labelLimit: `label` の最大文字数（既定 100、上限 200）。
    ///   - scene: 対象シーン。省略時は前面のシーン。
    ///   - completion: メインスレッドで 1 回だけ呼ばれる。
    /// - Returns: `cancel()` で中止できるハンドル。
    @MainActor
    @discardableResult
    public static func pickTarget(
        screenName: String? = nil,
        labelLimit: Int = FeedpulseTargetLimits.defaultLabel,
        scene: UIWindowScene? = nil,
        completion: @escaping (Result<FeedpulseTarget, FeedpulsePickError>) -> Void
    ) -> FeedpulsePickerSession {
        let session = FeedpulsePickerSession()
        guard activeSession == nil else {
            session.finish()
            completion(.failure(.alreadyActive))
            return session
        }
        guard let scene = scene ?? foregroundScene() else {
            session.finish()
            completion(.failure(.noActiveScene))
            return session
        }

        var overlay: PickerOverlay?
        let finish: (Result<FeedpulseTarget, FeedpulsePickError>) -> Void = { result in
            overlay?.dismiss()
            overlay = nil
            session.finish()
            activeSession = nil
            completion(result)
        }
        overlay = PickerOverlay(scene: scene) { [weak scene] point in
            guard let scene, let overlayWindow = overlay?.overlayWindow else {
                finish(.failure(.noActiveScene))
                return
            }
            let target = resolveTarget(in: scene, excluding: overlayWindow, at: point,
                                       screenName: screenName, labelLimit: labelLimit)
            finish(.success(target))
        }
        session.onCancel = { finish(.failure(.cancelled)) }
        activeSession = session
        return session
    }

    /// 実行中のピッカーがあれば中止する。
    @MainActor
    public static func cancelPicker() { activeSession?.cancel() }

    /// `async` 版。タスクのキャンセルでピッカーも中止する（`CancellationError` を投げる）。
    @MainActor
    public static func pickTarget(
        screenName: String? = nil,
        labelLimit: Int = FeedpulseTargetLimits.defaultLabel,
        scene: UIWindowScene? = nil
    ) async throws -> FeedpulseTarget {
        var session: FeedpulsePickerSession?
        let result: Result<FeedpulseTarget, FeedpulsePickError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                session = pickTarget(screenName: screenName, labelLimit: labelLimit, scene: scene) {
                    continuation.resume(returning: $0)
                }
            }
        } onCancel: {
            Task { @MainActor in session?.cancel() }
        }
        if Task.isCancelled, case .failure(.cancelled) = result { throw CancellationError() }
        return try result.get()
    }

    // MARK: 内部

    @MainActor
    private static func foregroundScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
    }

    /// オーバーレイ以外の最前面ウィンドウから、タップ座標の要素を引く。
    @MainActor
    private static func resolveTarget(
        in scene: UIWindowScene,
        excluding overlay: UIWindow,
        at point: CGPoint,
        screenName: String?,
        labelLimit: Int
    ) -> FeedpulseTarget {
        let windows = scene.windows
            .filter { $0 !== overlay && !$0.isHidden && $0.alpha > 0 }
            .sorted { $0.windowLevel > $1.windowLevel }
        let window = windows.first { win in
            let local = win.convert(point, from: overlay)
            guard let hit = win.hitTest(local, with: nil) else { return false }
            return hit !== win || win.isKeyWindow
        } ?? scene.windows.first { $0.isKeyWindow }
        guard let window else { return FeedpulseTarget(platform: .ios, screen: screenName, path: "UIWindow") }
        let local = window.convert(point, from: overlay)
        return TargetResolver.resolve(in: window, at: local, screenName: screenName, labelLimit: labelLimit)
    }
}
#endif
