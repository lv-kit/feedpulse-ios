# FeedPulse iOS — エージェント向けガイド

FeedPulse（Cloudflare Workers 上のフィードバック収集・配信 SaaS）の iOS 向けクライアント。Swift / Xcode ベースのネイティブアプリ。
バックエンド API は `lv-kit/feedpulse-web` の `apps/ingest`（公開 API）。API の仕様変更はそちらを正とする。

定義されていないコマンドを推測で書かない。

## 構成

- Swift Package（`Package.swift`、iOS 15+ / macOS 12+）。ライブラリ `Feedpulse` 1つ。CocoaPods 用に `Feedpulse.podspec` もある
- `Sources/Feedpulse/SDK/`: 送信・設定取得・検証・App Attest。`Sources/Feedpulse/Picker/`: 該当箇所ピッカー（UIKit 依存）
- `Tests/FeedpulseTests/`: 単体テスト。`Fixtures/` は契約 fixture（下記）

## 検証

CI（`.github/workflows/ci.yml`）と同じ形で実行する。

- `swift test`: macOS で実行（UIKit 依存のピッカーを除く）
- `xcodebuild build -scheme Feedpulse -destination 'generic/platform=iOS Simulator'`: CI のビルド
- `xcodebuild test -scheme Feedpulse -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`: シミュレーターでの全テスト（機種名は `xcrun simctl list devices available` で確認する）

実機の App Attest は自動テストで確認できない（README の「既知の限界」）。

## API 契約

- 正本は `lv-kit/feedpulse-web` の `packages/shared/src/native/`。`Tests/FeedpulseTests/Fixtures/contract.json` と `schemas/` はその複製で、手で編集しない
- 契約が変わったら、正本の fixture で置き換え、README の複製元コミットの記載も更新する。`ContractTests.swift` が fixture を再生して SDK を検証する
- 他の SDK（android / rn / flutter）と契約・挙動を揃える。仕様の追加・変更は正本側で決める

## リリース

手順は `RELEASING.md`。バージョンは `Feedpulse.podspec` の `version` と `CHANGELOG.md`。タグ付けと Releases の作成はメンテナが行う。エージェントはタグを打たない。

## 言語ルール

- **Issue・PR（タイトル・本文・コメント・レビュー返信）・コミットメッセージ**: 日本語
- **コード・識別子・コマンド・ログ出力**: 原文のまま（英語のまま書く）

## Git の運用

- force-push 禁止
- rebase 禁止（履歴を書き換えない）
- `main` への取り込みは merge（merge commit または GitHub の merge。rebase merge は使わない）
- `git commit --no-verify` 禁止（フックを迂回しない）

## 秘密情報

- 秘密値・本番キー・署名鍵・証明書・プロビジョニングプロファイルをコミットしない
- API キーや環境ごとの値はリポジトリ外で管理する。置いてよいのはダミー値の雛形ファイル（`*.example` 等）だけ

## 変更後の流れ

ファイルを変更したら、PR の作成まで行う。コミットだけで終わらせない。

1. 変更内容に応じて、ビルドと該当テストを実行する
2. 日本語のコミットメッセージでコミットする（「Git の運用」に従う）
3. ブランチを push する
4. `main` 向けの PR を作成する（「PR の書き方」に従う）

ファイルを変更しない作業（調査・質問への回答）には適用しない。ユーザーが「コミットまで」「PR は不要」など範囲を指定したときは、その指示を優先する。

## PR の書き方

- 本文に `Closes` / `Fixes` / `Resolves` を勝手に書かない（リンク Issue の自動クローズはメンテナが判断）
- 画面・UI に関わる PR には変更前後のスクリーンショットを付ける

## エージェント向け注意

- 本番環境・本番データには接続しない

## コンテキスト節約

- ファイル全体を読む前に検索し、必要な箇所だけ読む
- コード検索は [semble](https://github.com/MinishLab/semble) を grep より優先する。`semble --version` で確認し、無ければ `uvx --from "semble[mcp]" semble` を使う。どちらも使えなければ grep
  - 検索: `semble search "自然言語またはシンボル名" . --top-k 10`（ドキュメント・設定は `--content docs` / `config` / `all`）
  - 類似箇所: `semble find-related <file> <line> .`
  - 正規表現・完全一致の検索は grep（semble は正規表現検索ではない）
  - 初回のみ Hugging Face からモデルを取得する。ネットワークが使えなければ grep
- プロジェクト探索はサブエージェントに任せ、要約だけ受け取る
- 変更内容はファイル全体ではなく diff で示す
- 決定済みの事項を蒸し返さない
- タスクが変わるときは `/compact` か新規セッションを提案する
- 回答は既定で短くする（詳細は求められたときだけ）

## Worktree・PR・merge の運用

AIエージェントは、次の3点に従う。他の節に merge の承認を求める記述があっても、この節を優先する。

1. **worktree は後始末する。** 作業用に作成した git worktree は、作業を終了したとき、またはその PR を merge したときに削除する（`git worktree remove <path>`、不要になったローカルブランチの削除、`git worktree prune`）。未コミット・未 push の変更が残っているときは、削除せずユーザーへ報告する。
2. **PR 作成までは自動で行う。** 変更を実装したら、確認を待たずにコミット・push・PR 作成まで実施する。
3. **PR は自動で merge してよい。** ユーザーから「merge しない」「確認してから merge」などの明示的な指示がない限り、PR を merge する。次のときは merge せず、状況をユーザーへ報告する。
   - 必須 CI が、課金・利用枠以外の理由で失敗している
   - 未対応の PR コメントや、ブロッキング指摘が残っている
   - production へのデプロイ、課金ジョブの起動、第三者リソース・認証情報の変更を伴う（これらは従来どおりユーザーの明示承認を要する。この規定の対象外）
