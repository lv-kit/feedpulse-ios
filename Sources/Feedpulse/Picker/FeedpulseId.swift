#if canImport(UIKit)
import UIKit
import SwiftUI

/// `.feedpulseId(...)` が背景に置く、操作を受けない目印ビュー。
/// 修飾したビューと同じ frame を持つので、ピッカーはタップ座標を含む目印から ID を引く。
final class FeedpulseIdMarkerView: UIView {
    var feedpulseId: String = ""
    var feedpulseLabel: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct FeedpulseIdMarker: UIViewRepresentable {
    let id: String
    let label: String?

    func makeUIView(context: Context) -> FeedpulseIdMarkerView {
        let view = FeedpulseIdMarkerView()
        view.feedpulseId = id
        view.feedpulseLabel = label
        return view
    }

    func updateUIView(_ view: FeedpulseIdMarkerView, context: Context) {
        view.feedpulseId = id
        view.feedpulseLabel = label
    }
}

extension View {
    /// ピッカーがこのビューを選んだとき、自動取得より優先される明示 ID を返す。
    ///
    /// SwiftUI は自動取得だと内部のホスティングビューまでしか辿れないため、
    /// 報告したい要素には明示 ID を付ける。`label` は顧客が決める固定文言（入力値は渡さないこと）。
    public func feedpulseId(_ id: String, label: String? = nil) -> some View {
        background(FeedpulseIdMarker(id: id, label: label))
    }
}
#endif
