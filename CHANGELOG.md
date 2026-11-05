# Changelog

## 0.2.0

- SDK 本体を追加。`Feedpulse.configure(publicKey:)` で初期化し、`FeedpulseClient`（`ObservableObject`）から使う。
  - App Attest（`DCAppAttestService`）によるアプリ証明と、`POST /v1/native/challenge` → `/v1/native/session` のセッション取得（900 秒キャッシュ、期限前に更新）。`keyId` は Keychain に保存。
  - `GET /v1/config` の取得とローカルキャッシュ（`max-age` の間は通信しない、失敗時は前回値）。
  - 項目定義に基づくクライアント側入力検証（`FeedpulseForm.validate`）。
  - `POST /v1/submit`: 冪等キーの自動生成、ネットワークエラー・429・5xx の再送（`Retry-After` を尊重）、`context.auto`（OS・ロケール・タイムゾーン・`target`）と `context.custom`。
  - `identify(token)` による身元確認トークンの受け渡し（`context.identity`）。
  - 契約のエラーコードに対応する `FeedpulseError` / `FeedpulseErrorCode`。
  - アプリ証明の差し替え口（`FeedpulseAttestationProvider`、ローカル開発用の `DevInsecureAttestationProvider`）。
- 契約 fixture（`contract.json`）を読む単体テストを追加。
- Package.swift に `.macOS(.v12)` を追加（`swift test` で SDK のロジックを検証するため。SDK の対象は引き続き iOS）。
- 実機の App Attest は未検証（README「既知の限界」参照）。

## 0.1.1

- CocoaPods 用の `Feedpulse.podspec` を追加（React Native ブリッジが依存する）。

## 0.1.0

- 該当箇所ピッカー（UIKit 自動取得 + SwiftUI `feedpulseId`）を追加。
