# feedpulse-ios

Feedpulse iOS SDK（SwiftPM / CocoaPods）。ヘッドレスで UI は同梱しない（画面は自社の Design System で組む）。

- アプリ証明（App Attest）→ ネイティブセッションの取得と更新
- 項目定義の取得（`GET /v1/config`）とローカルキャッシュ（失敗時は前回値）
- 項目定義に基づく入力検証
- 送信（`POST /v1/submit`）: 冪等キー・自動再送・`Retry-After` の尊重
- 身元確認トークンの受け渡し（`identify`）
- 該当箇所ピッカー（`context.auto.target`）

> **実機での App Attest は未検証。** 通信・検証・再送などの SDK ロジックは契約 fixture に対する単体テストで確認している（App Attest は `AppAttestServing` プロトコルで差し替えたテスト用の偽物）。`DCAppAttestService` を使う本番経路は実機とサーバー側の検証でしか確かめられない（「既知の限界」参照）。

## 導入

> **利用には Feedpulse への登録が必要。** SDK を使う前に <https://feedpulse.stargazy.xyz/> でアカウントを登録し、プロジェクトを作成して公開鍵（`pk_`）を発行する。

要件: iOS 15.0 以上 / Swift 5.9 以上。現時点では SwiftPM / CocoaPods のレジストリには未公開で、Git のタグ（最新は `0.2.0`）から取得する。

### Swift Package Manager

Xcode: **File > Add Package Dependencies…** に `https://github.com/lv-kit/feedpulse-ios.git` を入力し、バージョンルールを「Up to Next Major」で `0.2.0` にして、ターゲットに `Feedpulse` を追加する。

`Package.swift` の場合:

```swift
dependencies: [
    .package(url: "https://github.com/lv-kit/feedpulse-ios.git", from: "0.2.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [.product(name: "Feedpulse", package: "feedpulse-ios")]),
]
```

### CocoaPods

`Podfile` に追加して `pod install` を実行する（トランクには未公開なので Git とタグを指定する）。

```ruby
pod 'Feedpulse', :git => 'https://github.com/lv-kit/feedpulse-ios.git', :tag => '0.2.0'
```

導入後は `import Feedpulse` で使える。Info.plist の追加設定は要らない。

### 事前に必要なこと

1. **Feedpulse にアプリを登録する。** 管理画面でプロジェクトにアプリ（iOS）を登録する。入力するのは bundle ID と Apple の Team ID（10 文字）。未登録のアプリは `app_not_registered` で拒否され、登録を削除すると発行済みのセッションも次のリクエストから拒否される。
2. **App Attest の Capability を有効にする。** Xcode の *Signing & Capabilities* で **App Attest** を追加するか、entitlement に `com.apple.developer.devicecheck.appattest-environment`（開発ビルドは `development`、配布ビルドは `production`）を設定する。
3. **実機で動かす。** App Attest はシミュレーターでは使えない（`attestationUnsupported`）。ローカル開発サーバー向けの回避策は「ローカル開発」を参照。

## 使い方

```swift
import Feedpulse

// 起動時に 1 回。publicKey は管理画面の公開鍵（pk_...）。appId は省略すると Bundle ID。
let feedpulse = Feedpulse.configure(publicKey: "pk_...")
// 本番以外へ向けるとき: Feedpulse.configure(publicKey:, baseURL: URL(string: "https://...")!)
```

`FeedpulseClient` は `ObservableObject`。SwiftUI からそのまま使える（`@StateObject` / `@ObservedObject` / `@EnvironmentObject`、または `Feedpulse.client`）。

```swift
struct FeedbackView: View {
    @ObservedObject var feedpulse: FeedpulseClient
    @State private var title = ""

    var body: some View {
        VStack {
            if let form = feedpulse.forms.first {          // 項目定義（キャッシュを含む）
                Text(form.name)
                TextField(form.definition.blocks[0].label, text: $title)
                Button("送信") { Task { await send(form) } }
                    .disabled(feedpulse.isSubmitting)
            }
        }
        .task { _ = try? await feedpulse.refresh() }        // 取得（鮮度内のキャッシュがあれば通信しない）
    }

    func send(_ form: FeedpulseForm) async {
        let submission = FeedpulseSubmission(formId: form.id, values: ["<ブロックID>": .text(title)])
        do {
            let receipt = try await feedpulse.submit(submission)   // 検証 → セッション → POST /v1/submit
            print(receipt.id)
        } catch FeedpulseError.validation(let errors) {
            // errors: [ブロックID: .required / .tooLong / .invalidEmail ...]（通信していない）
        } catch let error as FeedpulseError where error.isRetryable {
            // 自動再送でも届かなかった。**同じ `submission` で** もう一度 submit すれば二重に保存されない
        } catch { /* その他 */ }
    }
}
```

公開 API（抜粋）:

| API | 内容 |
|---|---|
| `Feedpulse.configure(publicKey:baseURL:appId:attestation:)` / `configure(_ configuration:)` | 初期化して `FeedpulseClient` を返す。再送回数・キャッシュ先などは `FeedpulseConfiguration` |
| `client.forms` / `widget` / `form(id:)` / `form(slug:)` | 項目定義（`@Published`）。`FeedpulseForm.definition.blocks` が入力項目 |
| `client.refresh(force:)` | `GET /v1/config`。`isRefreshing` / `isStale` / `lastRefreshError` も公開 |
| `form.validate(values)` | クライアント側検証。`cleaned`（正規化済みの値）と `errors` を返す |
| `FeedpulseSubmission(formId:values:target:custom:idempotencyKey:)` | 送信 1 件。冪等キーは生成時に自動で入る |
| `client.submit(_:)` | 送信。`FeedpulseReceipt`（サーバー側の id）を返す。`isSubmitting` を公開 |
| `client.identify(_ token:)` / `Feedpulse.identify(_:)` | 身元確認トークンを渡す（`nil` で解除）。`isIdentified` を公開 |
| `FeedpulseError` / `FeedpulseErrorCode` / `FeedpulseFieldError` | エラー型（下記） |
| `FeedpulseAttestationProvider` / `AppAttestProvider` / `AppAttestServing` / `FeedpulseKeyStore` | アプリ証明の差し替え口（テスト・独自実装向け） |

入力値は `FeedpulseValue`（`.text` / `.number` / `.list`）。文字列・整数・配列リテラルからそのまま作れる（`["title": "t", "rating": 4, "tags": ["a", "b"]]`）。`custom` は `FeedpulseCustomValue`（文字列・数値・真偽値）。

### 送信の流れと `context`

- `submit` は項目定義（`forms`）で検証してから送る。定義が手元に無ければ先に 1 回取得する。サーバーも同じ規則で再検証する（クライアント検証は UX のため）。
- `context.auto` に OS（例 `iOS 17.2`）・ロケール・タイムゾーンを載せる（`sendsAutoContext: false` で無効化）。**該当箇所ピッカーの結果は `FeedpulseSubmission.target` に渡すと `context.auto.target` に載る**（上限に正規化される）。
- `context.custom` は `custom:` で渡した値、`context.identity` は `identify` で渡したトークン。
- 画像・ファイルの添付と Turnstile は扱わない（ネイティブ経路は Turnstile 不要）。`image` / `file` ブロックは UUID の配列の検証のみ。

### 再送と冪等キー

- 冪等キー（`^[A-Za-z0-9_-]{16,64}$`）は `FeedpulseSubmission` の生成時に SDK が作る（乱数 16 バイトの base64url）。自動再送でも、**失敗後にアプリが同じ値を渡し直す場合も**同じキーで送るので、サーバーは二重に保存しない。
- ネットワークエラー・HTTP 429・5xx を最大 3 回（`maxAttempts`）まで自動再送する。待ち時間は 0.5 秒から倍々（上限 8 秒、揺らぎ付き）。429 は `Retry-After` の秒数だけ待つ。`Retry-After` が `maxRetryAfterWait`（既定 30 秒）を超えるときは待たずに `rateLimited`（`retryAfter` 付き）を投げる。
- 4xx（`invalid_fields`・`identity_invalid`・`app_not_registered` など）は再送しない。`invalid_session` だけはセッションを取り直して 1 回だけ同じ内容を送り直す。

### エラー

`FeedpulseError` は次のいずれか。サーバーの拒否は `.api(FeedpulseAPIError)` で、`code`（契約のエラーコード）・`status`・`fields`（`invalid_fields` の項目別エラー）・`identityFailure`（`identity_invalid` の理由: `expired` など）・`retryAfter` を持つ。

| ケース | 意味 |
|---|---|
| `.api(e)` | `e.code`: `.invalidFields` `.identityInvalid` `.rateLimited` `.appNotRegistered` `.attestationFailed` `.invalidSession` `.quotaExceeded` `.projectReadOnly` ほか契約の全コード（未知は `.unknown(raw)`） |
| `.validation([ブロックID: FeedpulseFieldError])` | 送信前のクライアント検証で失敗（通信していない） |
| `.unknownForm(id)` | 項目定義に無い formId |
| `.invalidArgument(msg)` | 冪等キーの形式など引数が不正 |
| `.attestationUnsupported` / `.attestationUnavailable(msg)` | App Attest が使えない端末（シミュレーター等）/ 端末側の失敗 |
| `.network(msg)` / `.invalidResponse(status:)` / `.cancelled` | 通信失敗 / 契約外の応答 / キャンセル |

`error.isRetryable` は、時間を置いて同じ送信をやり直す意味があるか（ネットワーク・429・5xx）。

## アプリ証明とセッション

1. `POST /v1/native/challenge`（1 回限り・120 秒）で challenge を得る。
2. 初回は端末で App Attest の鍵を作って attestation（`keyId` も送る）、2 回目以降は assertion を作る。`clientDataHash` は `SHA256(challenge の UTF-8)`。
3. `POST /v1/native/session` でセッション（900 秒）を得る。`/v1/config` と `/v1/submit` には `X-FeedPulse-Platform: ios` と `Authorization: Bearer <session>` を付ける（`Origin` は付けない）。

- セッションはメモリに 900 秒キャッシュし、期限の 30 秒前に取り直す。同時に複数の呼び出しがあっても取得は 1 回にまとめる。`invalid_session` を受けたら取り直す。
- `keyId` は Keychain に保存する（この端末のみ・初回アンロック後に読める）。**サーバーが attestation を受理した後で保存する**。assertion が `attestation_failed` で拒否されたら鍵を捨て、新しい鍵で attestation からやり直す（1 回だけ）。
- challenge の期限切れ・再利用（`challenge_expired` / `invalid_challenge`）は challenge を取り直して再試行する（最大 3 周）。
- アプリ証明の失敗理由はサーバーが返さないので、SDK はそれ以上リトライしない。

### ローカル開発

シミュレーターでは App Attest が使えない。ローカルの ingest（`NATIVE_ATTEST_INSECURE_DEV=true` の `env.dev`）に向けるときだけ、証明をスキップできる。**本番では必ず拒否される**ので、リリースビルドに残さないこと。

```swift
#if DEBUG
Feedpulse.configure(publicKey: "pk_dev", baseURL: URL(string: "http://localhost:8787")!,
                    appId: "com.example.app", attestation: DevInsecureAttestationProvider())
#endif
```

## 項目定義のキャッシュ

- `refresh()` は `Cache-Control: max-age`（サーバーは 60 秒）の間は通信せずキャッシュを返す。`refresh(force: true)` は必ず通信する。
- 成功した応答は `Caches/Feedpulse/` に JSON で保存する（`baseURL` と `pk` ごと）。次回起動時に読み込み、起動直後から `forms` が埋まる。保存できなくても動く（キャッシュ無し）。OS が Caches を消すことがある。
- 通信に失敗したら**前回値を返す**（`isStale == true`、理由は `lastRefreshError`）。前回値も無いときだけ `refresh()` が投げる。回復して成功すると `isStale` は false に戻る。
- 公開版が上がったか（`forms[].version`）は、最新の取得結果で丸ごと置き換える。古い定義で送ってサーバーに拒否された（`invalid_fields` など）ときは `refresh(force: true)` で更新する。

## 身元確認（identify）

顧客のバックエンドが、プロジェクトの `sk_` で署名した JWT（HS256、有効 1 時間以内）を発行し、アプリがそれを SDK に渡す。**`sk_` をアプリに入れてはいけない。**

```swift
feedpulse.identify(tokenFromYourBackend)   // 以降の送信の context.identity にそのまま載る
feedpulse.identify(nil)                      // ログアウト時に解除
```

SDK はトークンを検証せず、メモリにだけ保持する（アプリ再起動で消える）。期限切れなどで `identity_invalid`（`identityFailure == .expired` など）が返ったら、バックエンドで再発行して `identify` し直し、同じ `FeedpulseSubmission` を再送する。プロジェクトが身元確認を必須にしていなければ省略できる。

## 既知の限界

- **実機の App Attest は未検証。** `DCAppAttestService` の呼び出し（`SystemAppAttestService`）と Keychain 保存（`KeychainKeyStore`）は、自動テストでは偽物に差し替えて確認しており、実機＋本番/開発の ingest での通しの確認は手動（リリース前）になる。
- `swift test`（macOS）/ `xcodebuild test`（シミュレーター）で通るのは、契約 fixture に対する HTTP の往復・再送・キャッシュ・検証のロジックまで。
- セッションは 900 秒の間、複数回の送信に使える。濫用の抑止はサーバーの IP と pk ごとのレート制限と登録アプリの照合で行う。
- 端末が App Attest 非対応・シミュレーター・Capability 未設定のときは送信できない。代替の経路は無い。
- 画像・ファイル添付、スクリーンショット、既定 UI は提供しない。
- 身元確認トークンは永続化しない。アプリの再起動後は `identify` し直す。
- 項目定義のキャッシュに有効期限切れの強制削除は無い（古くても通信失敗時は使う）。

## 該当箇所ピッカー

```swift
import Feedpulse

// 全面の透明オーバーレイを出し、次の 1 タップで要素を特定する。
let session = Feedpulse.pickTarget(screenName: "Checkout") { result in
    switch result {
    case .success(let target): pickedTarget = target   // FeedpulseSubmission(target:) に渡す → context.auto.target
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

上限（UTF-16）: id 200 / screen 512 / path 512（超過時は末尾を残し `…>` 前置）/ label 100〜200。制御文字は除去。
`rect` は window 座標の pt（整数丸め）。`platform` は既定 `ios`、RN ブリッジは `.reactNative`（`"react-native"`）に差し替える。
上限は ingest の `TARGET_LIMITS`（#106 確定値）と同じ。超過すると ingest は target ごと捨てるため SDK 側で切る。`rect` は各値の絶対値 1,000,000 以下・w/h 非負、範囲外は rect を省く。id と path のどちらかが無い target も捨てられる（SDK は path を常に付ける）。

## テスト

契約 fixture（`Tests/FeedpulseTests/Fixtures/contract.json` と `schemas/`）は lv-kit/feedpulse-web の `packages/shared/src/native/` からの複製（web の `38b29d6` 時点）。契約が変わったら置き換える。

```sh
swift test   # macOS: 契約テスト・再送・キャッシュ・検証・target 型（UIKit 依存のピッカーを除く）
xcodebuild test -scheme Feedpulse -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
