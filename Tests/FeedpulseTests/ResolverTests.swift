#if canImport(UIKit)
import XCTest
import SwiftUI
import WebKit
@testable import Feedpulse

@MainActor
final class ResolverTests: XCTestCase {
    private var window: UIWindow!
    private var root: UIViewController!

    override func setUp() async throws {
        root = UIViewController()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
    }

    private func resolve(_ x: CGFloat, _ y: CGFloat, screen: String? = nil, limit: Int = 100) -> FeedpulseTarget {
        window.layoutIfNeeded()
        return TargetResolver.resolve(in: window, at: CGPoint(x: x, y: y), screenName: screen, labelLimit: limit)
    }

    func testAutoCaptureWithoutIdentifier() {
        let button = UIButton(frame: CGRect(x: 20, y: 100, width: 100, height: 40))
        button.accessibilityLabel = "Send report"
        root.view.addSubview(button)
        let t = resolve(30, 110)
        XCTAssertNil(t.id)
        XCTAssertEqual(t.platform, .ios)
        XCTAssertEqual(t.label, "Send report")
        XCTAssertEqual(t.rect, .init(x: 20, y: 100, w: 100, h: 40))
        XCTAssertTrue(t.path!.hasSuffix("UIButton[0]"), t.path ?? "")
        XCTAssertTrue(t.path!.hasPrefix("UIWindow>"))
        XCTAssertEqual(t.screen, "UIViewController")
    }

    func testExplicitIdentifierOnAncestorWinsOverAutoCapture() {
        let card = UIView(frame: CGRect(x: 10, y: 200, width: 300, height: 120))
        card.accessibilityIdentifier = "checkout-card"
        let inner = UILabel(frame: CGRect(x: 10, y: 10, width: 100, height: 20))
        inner.text = "inner"
        card.addSubview(inner)
        root.view.addSubview(card)
        let t = resolve(30, 215)
        XCTAssertEqual(t.id, "checkout-card")
        XCTAssertEqual(t.rect, .init(x: 10, y: 200, w: 300, h: 120))
    }

    func testSwiftUIMarkerIsExplicitIdAndBeatsLargerUIKitId() {
        root.view.accessibilityIdentifier = "screen-root"
        let marker = FeedpulseIdMarkerView(frame: CGRect(x: 40, y: 300, width: 80, height: 44))
        marker.feedpulseId = "pay-button"
        marker.feedpulseLabel = "Pay"
        root.view.addSubview(marker)
        let t = resolve(50, 310)
        XCTAssertEqual(t.id, "pay-button")
        XCTAssertEqual(t.label, "Pay")
        XCTAssertEqual(t.rect, .init(x: 40, y: 300, w: 80, h: 44))
        // 目印の外では UIKit の明示 ID に戻る
        XCTAssertEqual(resolve(300, 700).id, "screen-root")
    }

    func testFeedpulseIdModifierBuildsMarker() {
        let host = UIHostingController(rootView: Text("Hi").frame(width: 120, height: 50).feedpulseId("hello", label: "Greeting"))
        window.rootViewController = host
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let marker = findMarker(in: host.view)
        XCTAssertEqual(marker?.feedpulseId, "hello")
        XCTAssertEqual(marker?.feedpulseLabel, "Greeting")
        XCTAssertEqual(marker?.isUserInteractionEnabled, false)
    }

    func testSecureFieldValueAndLabelAreNeverCaptured() {
        let field = UITextField(frame: CGRect(x: 20, y: 400, width: 200, height: 40))
        field.isSecureTextEntry = true
        field.text = "hunter2-SECRET"
        field.placeholder = "Password"
        field.accessibilityLabel = "hunter2-SECRET"
        field.accessibilityValue = "hunter2-SECRET"
        root.view.addSubview(field)
        let t = resolve(30, 410)
        XCTAssertNil(t.label)
        XCTAssertFalse(t.jsonString.contains("hunter2"))
        XCTAssertFalse(t.jsonString.contains("SECRET"))
        XCTAssertEqual(t.rect, .init(x: 20, y: 400, w: 200, h: 40))
    }

    func testTextFieldAndTextViewValuesAreNotCaptured() {
        let field = UITextField(frame: CGRect(x: 20, y: 450, width: 200, height: 40))
        field.text = "secret-email@example.com"
        field.accessibilityLabel = "secret-email@example.com" // 値と同一 → 採らない
        let tv = UITextView(frame: CGRect(x: 20, y: 500, width: 200, height: 80))
        tv.text = "private diary entry"
        root.view.addSubview(field)
        root.view.addSubview(tv)
        for (x, y) in [(30, 460), (30, 510)] as [(CGFloat, CGFloat)] {
            let t = resolve(x, y)
            XCTAssertFalse(t.jsonString.contains("secret-email"), t.jsonString)
            XCTAssertFalse(t.jsonString.contains("diary"), t.jsonString)
        }
    }

    func testTextFieldWithDeveloperLabelKeepsLabelNotValue() {
        let field = UITextField(frame: CGRect(x: 20, y: 450, width: 200, height: 40))
        field.text = "typed value"
        field.accessibilityLabel = "Email"
        root.view.addSubview(field)
        let t = resolve(30, 460)
        XCTAssertEqual(t.label, "Email")
        XCTAssertFalse(t.jsonString.contains("typed value"))
    }

    func testLabelIsTruncatedToLimit() {
        let v = UIView(frame: CGRect(x: 0, y: 600, width: 100, height: 50))
        v.isAccessibilityElement = true
        v.accessibilityLabel = String(repeating: "x", count: 300)
        root.view.addSubview(v)
        XCTAssertEqual(resolve(5, 610, limit: 12).label, String(repeating: "x", count: 12))
        XCTAssertEqual(resolve(5, 610).label?.count, 100)
    }

    func testCustomScreenNameWins() {
        XCTAssertEqual(resolve(5, 5, screen: "Settings").screen, "Settings")
    }

    func testWebViewResolvesToWholeWebView() {
        let web = WKWebView(frame: CGRect(x: 0, y: 100, width: 390, height: 500))
        root.view.addSubview(web)
        let t = resolve(100, 200)
        XCTAssertEqual(t.rect, .init(x: 0, y: 100, w: 390, h: 500))
        XCTAssertTrue(t.path!.hasSuffix("WKWebView[0]"), t.path ?? "")
    }

    func testTopViewControllerFollowsNavigationAndPresentation() {
        final class DetailVC: UIViewController {}
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(DetailVC(), animated: false)
        window.rootViewController = nav
        XCTAssertEqual(TargetResolver.topViewControllerName(of: window), "DetailVC")
    }

    func testPickerFailsWithoutScene() {
        let exp = expectation(description: "completion")
        Feedpulse.pickTarget(scene: nil) { result in
            // ホスト無しのテストでは前面シーンが無い。シーンがあるなら起動し、cancel で .cancelled。
            if case .failure(let e) = result { XCTAssertTrue(e == .noActiveScene || e == .cancelled) }
            exp.fulfill()
        }
        Feedpulse.cancelPicker()
        wait(for: [exp], timeout: 2)
    }

    private func findMarker(in view: UIView) -> FeedpulseIdMarkerView? {
        if let m = view as? FeedpulseIdMarkerView { return m }
        for s in view.subviews { if let m = findMarker(in: s) { return m } }
        return nil
    }
}
#endif
