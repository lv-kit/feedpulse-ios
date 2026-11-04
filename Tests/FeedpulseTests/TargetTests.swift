import XCTest
@testable import Feedpulse

final class TargetTests: XCTestCase {
    func testJSONShapeMatchesSchema() throws {
        let t = FeedpulseTarget(platform: .ios, screen: "HomeVC", id: "buy", path: "UIWindow>UIView[0]",
                                rect: .init(x: 1, y: 2, w: 3, h: 4), label: "Buy")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(t.jsonString.utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["platform", "screen", "id", "path", "rect", "label"])
        XCTAssertEqual(obj["platform"] as? String, "ios")
        XCTAssertEqual(Set((obj["rect"] as? [String: Any])?.keys.map { $0 } ?? []), ["x", "y", "w", "h"])
    }

    func testNilFieldsAreOmitted() {
        let obj = FeedpulseTarget().jsonObject
        XCTAssertEqual(Set(obj.keys), ["platform"])
    }

    func testReactNativePlatformRawValue() {
        XCTAssertEqual(FeedpulseTarget(platform: .reactNative).jsonObject["platform"] as? String, "react-native")
    }

    func testSanitizeLimitsAndControlChars() {
        let t = FeedpulseTarget(screen: String(repeating: "a", count: 500), id: "i\u{0}d\n",
                                path: String(repeating: "x", count: 2000), label: String(repeating: "あ", count: 500))
        let s = TargetSanitizer.sanitize(t, labelLimit: 30)
        XCTAssertEqual(s.screen?.utf16.count, 500)
        XCTAssertEqual(TargetSanitizer.sanitize(FeedpulseTarget(screen: String(repeating: "a", count: 900))).screen?.utf16.count, 512)
        XCTAssertEqual(s.id, "id")
        XCTAssertLessThanOrEqual(s.path?.utf16.count ?? 0, FeedpulseTargetLimits.path)
        XCTAssertEqual(s.label?.count, 30)
    }

    func testLabelLimitCappedAtMax() {
        let s = TargetSanitizer.sanitize(FeedpulseTarget(label: String(repeating: "a", count: 999)), labelLimit: 9999)
        XCTAssertEqual(s.label?.count, FeedpulseTargetLimits.maxLabel)
    }

    func testNonFiniteRectDropped() {
        for bad in [Double.nan, .infinity, -.infinity] {
            let s = TargetSanitizer.sanitize(FeedpulseTarget(rect: .init(x: bad, y: 0, w: 1, h: 1)))
            XCTAssertNil(s.rect)
        }
    }

    func testLimitsMatchIngest() {
        XCTAssertEqual(FeedpulseTargetLimits.screen, 512)
        XCTAssertEqual(FeedpulseTargetLimits.id, 200)
        XCTAssertEqual(FeedpulseTargetLimits.path, 512)
        XCTAssertEqual(FeedpulseTargetLimits.maxLabel, 200)
        XCTAssertEqual(FeedpulseTargetLimits.rectAbs, 1_000_000)
        let raw = ["web", "ios", "android", "flutter", "react-native"]
        XCTAssertEqual([FeedpulseTarget.Platform.web, .ios, .android, .flutter, .reactNative].map(\.rawValue), raw)
    }

    func testRectOutOfRangeOrNegativeSizeDropped() {
        XCTAssertNil(TargetSanitizer.rect(.init(x: 1_000_001, y: 0, w: 1, h: 1)))
        XCTAssertNil(TargetSanitizer.rect(.init(x: 0, y: -1_000_001, w: 1, h: 1)))
        XCTAssertNil(TargetSanitizer.rect(.init(x: 0, y: 0, w: -1, h: 1)))
        XCTAssertNotNil(TargetSanitizer.rect(.init(x: -50, y: -20, w: 10, h: 10)))
    }

    func testEmptyStringsBecomeNil() {
        let s = TargetSanitizer.sanitize(FeedpulseTarget(screen: "  ", id: "", label: "\n"))
        XCTAssertNil(s.screen); XCTAssertNil(s.id); XCTAssertNil(s.label)
    }

    func testPathKeepsDeepestSegments() {
        let long = (0..<200).map { "UIView[\($0)]" }.joined(separator: ">")
        let s = TargetSanitizer.sanitize(FeedpulseTarget(path: long))
        XCTAssertTrue(s.path!.hasPrefix("…>"))
        XCTAssertTrue(s.path!.hasSuffix("UIView[199]"))
    }
}
