# feedpulse-ios

Feedpulse iOS SDK（SwiftPM）。ヘッドレスで UI は同梱しない。現在は「該当箇所ピッカー」（lv-kit/feedpulse-web#114）を実装している。
`/v1/config`・`/v1/submit`・App Attest（#3 P3）は未実装。

## 該当箇所ピッカー

```swift
import Feedpulse

// 全面の透明オーバーレイを出し、次の 1 タップで要素を特定する。
let session = Feedpulse.pickTarget(screenName: "Checkout") { result in
    switch result {
    case .success(let target): form.target = target.jsonObject   // context.auto.target
    case .failure(let error):  break                              // .cancelled / .noActiveScene / .alreadyActive
    }
}
session.cancel()          // または Feedpulse.cancelPicker()

let target = try await Feedpulse.pickTarget()   // async 版。Task キャンセルで中止
```

- UIKit: タップ座標で `hitTest`。`accessibilityIdentifier`（祖先で最も近いもの）を明示 ID として採用。
- SwiftUI: `.feedpulseId("pay-button", label: "Pay")`。自動取得はホスティングビュー止まりなので明示 ID を前提にする。
- 明示 ID（UIKit の identifier / SwiftUI の目印）は自動取得より優先。複数あれば面積が最小のもの。
- `WKWebView` 上のタップは WebView 全体の frame と URL（クエリ・フラグメントなし）。
- 取得しない: `UITextField` / `UITextView` の値、secure 入力に紐づく label、スクリーンショット。
- `label` は `accessibilityLabel` の先頭 N 文字（既定 100、上限 200）。

## target の形

`context.auto.target`（#105 / #106）。nil のキーは出力しない。

```json
{ "platform": "ios", "screen": "HomeViewController", "id": "pay-button",
  "path": "UIWindow>UIView[0]>UIButton[2]",
  "rect": { "x": 20, "y": 100, "w": 100, "h": 40 }, "label": "Pay" }
```

上限（UTF-16）: id 200 / screen 200 / path 512（超過時は末尾を残し `…>` 前置）/ label 100〜200。制御文字は除去。
`rect` は window 座標の pt（整数丸め）。`platform` は既定 `ios`、RN ブリッジは `.reactNative`（`"react-native"`）に差し替える。
上限は #106 確定前の仮値。確定したら `FeedpulseTargetLimits` を合わせる。

## テスト

```sh
swift test   # macOS: target 型・正規化のみ
xcodebuild test -scheme Feedpulse -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
