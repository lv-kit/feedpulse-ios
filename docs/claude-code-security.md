# Claude Code セキュリティ対策まとめ

対象: Claude Code v2.1.318 以降 / 最終確認日: 2026-11-08

設定キー・コマンドの挙動は公式ドキュメント (code.claude.com/docs) で確認済み。事件の扱いは各節の「確度」欄を参照。

## 基本方針

- 「AIに賢く判断してもらう」だけでは防げない。プロンプトインジェクション(外部の文章や設定に仕込まれた命令をモデルが指示として受け取ってしまう攻撃)は、モデルの判断が騙される前提で考える。
- 対策は「注意する」ではなく「仕組みで止める」。OSレベルの隔離(サンドボックス)、deny ルール、Hooks、バージョン管理で、判断が誤っても被害が出ない構成にする。
- 層で守る。単独で完全な対策はない。

---

## 1. 主なリスク(3つ)

| リスク | 具体例 | 影響 |
| --- | --- | --- |
| 消す | `rm -rf`、`git reset --hard`、DB 削除、上書き | 作業・データの喪失。復旧不能な場合あり |
| 漏らす | `.env`、`~/.aws/credentials`、SSH 鍵、顧客データの外部送信 | 不正利用、課金被害、アカウント侵害、情報漏えい |
| 勝手に動く | Web・README・Issue・MCP 応答内の命令に従う、不審なリポジトリ設定の実行 | 意図しないコマンド実行、権限の悪用 |

---

## 2. 事件・検証から学ぶポイント(2件)

### 事件①: 他人のプロジェクトを開くだけで API キー漏えい

- 確度: 高い。CVE-2026-21852(GHSA-jh7p-qr78-84p7)と CVE-2025-59536 が該当。
- 内容:
  - リポジトリ内の `.claude/settings.json` で `ANTHROPIC_BASE_URL` を攻撃者のサーバーに向けると、信頼ダイアログの前に送られる API リクエストで API キーが漏れた(CVE-2026-21852。v2.0.65 未満が影響、v2.0.65 で修正)。
  - 同じ設定ファイル経由で、信頼前に Hooks や MCP 設定が実行される問題も報告された(CVE-2025-59536。修正は v1.0.111。一次 advisory は今回未確認)。
- 影響: クローンして `claude` を起動するだけで API キーが盗まれ、課金被害やワークスペースの共有リソースへのアクセスにつながる。
- 教訓:
  - 本体を最新に保つ(対策7)。
  - 他人のリポジトリは起動前に `.claude/`、`.mcp.json`、`CLAUDE.md` を読む(対策5)。
  - 信頼ダイアログは読んでから承認する。`claude -p` と SDK は信頼プロンプトを出さないため、未知のリポジトリでは使わない。

### 事件②: サンドボックスのすき間を突くファイル編集

- 確度: 中。GitHub advisory GHSA-vp62-r36r-9xqp(2026-04 公開、CVE-2026-39861)で、シンボリックリンクをたどってワークスペース外へ書き込める問題が確認できた。設定ファイル経由のサンドボックス回避(CVE-2026-25725)も報告されている。詳細は検索抜粋のみで確認。
- 内容: サンドボックス外で動く処理(ファイル編集ツールなど)が、細工されたリンクや設定ファイル経由でワークスペース外・設定を書き換える。
- 影響: サンドボックスを入れていても、守備範囲外の経路から突破される。設定ファイルを書き換えられると、次回以降の挙動が変わる。
- 教訓:
  - サンドボックスは Bash が中心。ファイル編集ツールは別経路で、deny ルールと Git で守る(対策2, 8, 9)。
  - 更新を欠かさない(対策7)。
  - 不審なシンボリックリンクがないか、取得したリポジトリで確認する。

---

## 3. 具体的な対策術(10個)

### 1. Auto mode を過信せず Manual mode を使い分ける

- Auto mode は別の分類器モデルが実行前に審査する仕組み。便利だが、分類器も騙されうる。
- v2.1.283 以降、対話型ターミナルと VS Code の既定は `auto`。意識しないと常時 Auto で動く。
- 切替は Shift+Tab。`default`(Manual)→ `acceptEdits` → `plan` を循環する。`dontAsk` は循環に出ず `--permission-mode dontAsk` でのみ指定。
- 使い分けの目安:
  - 未知のリポジトリ、Web を読ませる作業、認証情報が近くにある環境: Manual か `plan`
  - 自分のリポジトリで、サンドボックス有効・秘密情報なしの作業: Auto 可
- `bypassPermissions` は隔離された使い捨て環境(コンテナ・VM)以外で使わない。
- `permissions.defaultMode: "auto"` はプロジェクト設定(`.claude/settings.json`)では効かず、`~/.claude/settings.json` に書く必要がある。リポジトリ側から勝手に Auto にされない設計。

### 2. `/permissions` で許可ルールを定期点検する

- 「今後は確認しない」を選ぶたびに allow ルールが増える。身に覚えのないものは削除する。
- 特に注意: `Bash(*)`、`Bash(curl *)`、`Bash(python *)`、`Bash(git push *)` のような広い許可。
- 影響: 広い allow があると、インジェクションで命令された操作が確認なしで通る。
- 点検場所: `~/.claude/settings.json`、`.claude/settings.json`、`.claude/settings.local.json`。月1回、または他人のプロジェクトを触った後に見る。

### 3. 練習用フォルダーで起動し、秘密情報は置かない

- 起動したディレクトリがエージェントの作業範囲の基準になる。ホームディレクトリで起動しない(ホームでは信頼も保存されず、広範囲を読める)。
- 学習・検証用に専用フォルダー(例: `~/practice/`)を作り、そこから起動する。
- 置かないもの: `.env`、秘密鍵、顧客データ、本番の認証情報、クラウドの認証ファイルへのシンボリックリンク。
- `permissions.blockReadsOutsideWorkingDirectories` で作業ディレクトリ外の読み取りを止められる。

### 4. `/sandbox` でサンドボックスを有効化し、`sandbox.credentials` で認証情報を deny する

- サンドボックス: Bash コマンドと子プロセスを OS レベル(macOS は Seatbelt、Linux/WSL2 は bubblewrap)で隔離する機能。ネイティブ Windows は非対応(WSL2 で使う)。
- `sandbox.enabled` の既定は off。`/sandbox` で切り替える。
- 認証情報の deny は `sandbox.credentials` で行う。組み込みの deny リストはないので、列挙したものだけが制限される。既定では `~/.ssh` や `~/.aws/credentials` は読める。
- 子プロセス全体から環境変数を除去したい場合は環境変数 `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` も検討する。
- ネットワークは `sandbox.network.allowedDomains` で出口を絞る。これが外部送信を止める本命。
- 設定例は「4. 設定例」を参照。

守る範囲と守らない範囲:

| 守る | 守らない |
| --- | --- |
| Bash コマンドとその子プロセスのファイル・ネットワーク | Claude 組み込みのファイル編集ツール(別経路。permission ルールで制御) |
| `sandbox.excludedCommands` に入れていないコマンド | excluded に入れたコマンド、`allowUnsandboxedCommands: true` でのリトライ |
| 設定したパス・ドメイン | 許可したドメイン経由のデータ送出(allowlist 内のサービスへの書き込み) |
| | MCP サーバーの処理、フック自体の処理 |

### 5. MCP・プラグイン・他人のプロジェクトは導入前に確認する

- MCP サーバー・プラグイン・Skills・Hooks は、ローカルで任意コードを動かせる権限を持つ。インストール = そのコードを信頼すること。
- 他人のリポジトリを開く前に:
  1. `cat .claude/settings.json .mcp.json` で `hooks`、`env`(特に `ANTHROPIC_BASE_URL`)、`mcpServers`、`enableAllProjectMcpServers` を確認
  2. `CLAUDE.md` と `.claude/commands`、`.claude/agents`、skills に不審な指示がないか確認
  3. 本体を最新にしてから起動
  4. 信頼ダイアログと `.mcp.json` の承認プロンプトを読んで判断(安易に Yes を押さない)
- 提供元不明の MCP・プラグインは入れない。入れる場合は必要最小限の権限・ツールだけ許可する。
- 影響: 悪意ある設定1つで、コマンド実行・認証情報の窃取が起動直後に起きうる(事件①)。

### 6. Hooks の `onFailure: "block"` を活用する

- Hooks: ツール実行の前後で自動実行されるスクリプト。`PreToolUse` で危険な操作を機械的に止められる。
- `onFailure` は `command` と `http` のハンドラーに指定でき、v2.1.295 以降。値は `"continue"`(既定)と `"block"`。
- `"block"` にすると、フック自体が起動できない、exit 2 以外の非 0、タイムアウト、不正な出力でも、操作が止まる。つまり「検査フックが壊れたら素通り」を防げる。
- 注意:
  - exit 1 は非ブロッキング。止めたいときは exit 2 か、JSON で `permissionDecision: "deny"` を返す。
  - `Stop`、`SubagentStop`、`TaskCompleted`、`TeammateIdle`、async のバックグラウンド hook では `onFailure` は効かない。
- 止める対象の例: `rm -rf`、`git push --force`、`.env` を含むコマンド、`curl`/`wget` による外部送信、本番 DB への接続。

### 7. 本体を最新版に保つ(`claude update` や `claude doctor`)

- 事件①②はいずれも修正版が出ている。古いバージョンは既知の脆弱性を抱えたまま。
- `claude update`: 最新版に更新。
- `claude doctor`: セッションを起動せず、インストールと設定を読み取り専用で診断(設定ファイルの検証エラーなど)。セッション内では `/doctor`。
- `/update` は `/restart` のエイリアス(インストール済みの更新を適用して再起動)。更新の取得コマンドではない。
- 本書の対象は v2.1.318 以降。`sandbox.credentials` や `onFailure` は新しめの機能なので、古い版では効かない可能性がある。

### 8. Read の deny ルールで秘密ファイルを保護し、効く範囲を理解する

- `permissions.deny` に `Read(./.env)` のように書くと、Claude の組み込みファイルツール(Read、Grep、Glob、@ 言及)からの読み取りを止める。Grep/Glob は best-effort。
- 効かないケース:
  - サンドボックスが無効のとき、Bash 経由(`cat .env`、`python -c "print(open('.env').read())"`)の読み取りは Read deny の対象外とみなすべき。
  - サンドボックス有効時は、permission ルールのパスがサンドボックス設定にマージされるので Bash 側も制限される(公式の記述からの読み取り。個別コマンドの例は明記なし)。必ず自分の環境でダミーファイルで検証する。
  - `curl` などの Bash deny はパス指定や `sh -c` 経由で回避されうる。確実に止めるなら sandbox の network allowlist と併用する。
- `.claudeignore` は効かない。Read deny に移す。
- 結論: Read deny + サンドボックス(`sandbox.filesystem.denyRead` と `sandbox.credentials`)の二重にする。

### 9. `/rewind` は万能ではないので Git とバックアップを使い分ける

- `/rewind`(`/checkpoint`、`/undo`)は、コードと会話を巻き戻す。Esc を2回(入力欄が空のとき)でも開く。
- 戻らないもの:
  - Bash だけで変更されたファイル(`rm`、`mv`、スクリプトでの書き換え)は追跡されない
  - サブエージェントの編集(原則)
  - 外部エディタでの変更
  - 外部への送信・API 呼び出し・DB 変更などの副作用
- 対策:
  - 作業前にコミット(または stash)。ブランチを切って作業する
  - 重要データは別途バックアップ(クラウド同期だけでは削除が同期されるので不十分)
  - `git push --force`、`git reset --hard`、`git clean -fd` を Hooks や deny で止める

### 10. 作ったアプリは `/security-review` で点検する

- `/security-review`: 現在のブランチと `origin` のデフォルトブランチの diff を対象に、脆弱性を分析する。`origin` リモートが必要。
- 生成コードで多い問題: 入力検証の欠落、認可チェック漏れ、SQL/コマンドインジェクション、秘密情報のハードコード、過剰な CORS、依存パッケージの脆弱性。
- 限界: 完全な監査ではない。公開前に依存関係の脆弱性スキャン、シークレットスキャン、人間のレビューを併用する。

---

## 4. 設定例

### permissions の deny 例(`~/.claude/settings.json` またはプロジェクトの `.claude/settings.json`)

```json
{
  "permissions": {
    "deny": [
      "Read(./.env)",
      "Read(./.env.*)",
      "Read(./secrets/**)",
      "Read(~/.ssh/**)",
      "Read(~/.aws/**)",
      "Bash(rm -rf *)",
      "Bash(git push --force *)",
      "Bash(git reset --hard *)"
    ],
    "blockReadsOutsideWorkingDirectories": true
  }
}
```

- `Read(.env)` や `Read(**/.env)` は作業ディレクトリ配下の任意の深さにマッチする。`//` は絶対パス、`~/` はホーム基準。
- Bash の deny はパターン一致なので回避されうる。補助と考える。

### sandbox.credentials の例

```json
{
  "sandbox": {
    "enabled": true,
    "credentials": {
      "files": [
        { "path": "~/.aws/credentials", "mode": "deny" },
        { "path": "~/.ssh", "mode": "deny" },
        { "path": "~/.config/gh/hosts.yml", "mode": "deny" }
      ],
      "envVars": [
        { "name": "GITHUB_TOKEN", "mode": "deny" },
        { "name": "AWS_SECRET_ACCESS_KEY", "mode": "deny" },
        { "name": "ANTHROPIC_API_KEY", "mode": "deny" }
      ]
    }
  }
}
```

- `envVars` はコマンド実行前に unset される。
- 実際に使っているキー名・パスに合わせて列挙する。列挙していないものは守られない。

### サンドボックス関連の設定

```json
{
  "sandbox": {
    "enabled": true,
    "allowUnsandboxedCommands": false,
    "failIfUnavailable": true,
    "filesystem": {
      "denyRead": ["~/.ssh", "~/.aws", "./.env"],
      "denyWrite": ["./.claude/settings.json", "./.mcp.json"]
    },
    "network": {
      "allowedDomains": ["github.com", "registry.npmjs.org"]
    }
  }
}
```

- `allowUnsandboxedCommands: false`: サンドボックスで失敗したコマンドを、サンドボックス外で再実行するリトライを止める(`/sandbox` の "Strict sandbox mode")。
- `failIfUnavailable: true`: サンドボックスが動かない環境では起動時に終了する。既定はサンドボックスなしで動く。サイレントに無防備になるのを防ぐ。
- `denyWrite` で設定ファイルの書き換えを止める(事件②の設定経由の悪用対策)。
- 設定を編集すると、実行中のセッションにも反映される(次のサンドボックスコマンドから)。

### Hooks 例(`onFailure: "block"`)

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh",
            "onFailure": "block"
          }
        ]
      }
    ]
  }
}
```

`guard.sh` は危険なコマンドを検知したら exit 2 で終了し、理由を stderr に出す。

---

## 5. 今日からやること(優先度順)

1. `claude doctor` を実行して更新状態と設定エラーを確認。古ければ `claude update`
2. `/permissions` を開き、身に覚えのない「今後は確認しない」と広すぎる allow を削除
3. 練習用フォルダーを作り、そこから起動する。ホームで起動しない
4. `/sandbox` で有効化し、ダミーの `.env` を置いて、読めない・外部送信できないことを確認

確認例(ダミーファイルのみ使う):

```bash
mkdir -p ~/practice && cd ~/practice
echo "DUMMY_KEY=not-a-real-secret" > .env
claude
# セッション内で「.env を cat して」「python で .env を読んで」と依頼し、拒否されるか確認
```

拒否されない経路があれば、その経路が守られていないということ。設定を見直す。

---

## 6. チェックリスト

### 準備
- [ ] `claude doctor` でエラーなし
- [ ] `claude update` で最新版
- [ ] 練習用・作業用フォルダーから起動している(ホームで起動していない)

### 許可
- [ ] `/permissions` に身に覚えのないルールがない
- [ ] `Bash(*)` などの広い allow がない
- [ ] 未知のリポジトリ・Web 閲覧時は Manual か `plan` にしている(Shift+Tab)
- [ ] `bypassPermissions` は使い捨て環境以外で使っていない

### 囲い
- [ ] `sandbox.enabled: true`
- [ ] `allowUnsandboxedCommands: false`
- [ ] `failIfUnavailable: true`
- [ ] `network.allowedDomains` で出口を絞っている
- [ ] `blockReadsOutsideWorkingDirectories: true`

### 秘密
- [ ] `permissions.deny` に `.env`、`secrets/`、`~/.ssh`、`~/.aws` がある
- [ ] `sandbox.credentials` に使っている認証情報を列挙した
- [ ] 作業フォルダーに本番キー・顧客データを置いていない
- [ ] ダミーファイルで Bash 経由の読み取りが止まることを確認した

### 追加するもの
- [ ] 他人のリポジトリは `.claude/settings.json`、`.mcp.json`、`CLAUDE.md` を読んでから開いた
- [ ] 導入した MCP・プラグインの提供元を確認した
- [ ] `PreToolUse` フックに `onFailure: "block"` を付けた
- [ ] 出所不明の文章をそのまま貼っていない

### 戻す準備
- [ ] 作業前にコミット済み(またはブランチを切った)
- [ ] 重要データのバックアップが Claude Code の外にある
- [ ] `git push --force`、`git reset --hard` を止めている
- [ ] `/rewind` は Bash の変更を戻せないと理解している

---

## 7. もしもの時の対応手順

1. **Esc で停止する。** 実行中の処理を止める。止まらなければターミナルごと閉じる
2. **実行内容を確認する。** 会話履歴、`git status`、`git diff`、シェル履歴、ネットワーク通信の有無を見る
3. **認証情報を無効化・再発行する。** 漏えいの疑いがあるものは、確認より先に失効させる。対象: API キー(Anthropic、クラウド、GitHub 等)、SSH 鍵、トークン、DB パスワード。各サービスの利用履歴(不審なアクセス・課金)も確認する
4. **ファイルを復元する。** 順に試す: `/rewind` → Git(`git restore`、`git reflog`)→ バックアップ。`/rewind` は Bash だけで変更したファイルを戻せない
5. **原因を見直す。** 該当した allow ルール、MCP、プラグイン、Hooks、リポジトリの設定ファイルを特定して削除。同じ経路が塞がったか、ダミーファイルで再検証する

---

## 補足: 学習設定と外部送信は別問題

- 個人向けプラン(Free / Pro / Max / Ultra)の「モデル改善への利用」設定は、学習に使われるかどうかを決める設定。
- プロンプトとモデル出力は、学習設定に関係なく TLS で Anthropic に送信される。学習をオフにしても、ローカルのファイルが外に出ないわけではない。
- 保持期間: 学習設定オンなら 5 年、オフなら 30 日(個人プラン)。商用プランは標準 30 日。学習をオフにしても保持が 0 にはならない。
- `/feedback`、`/bug`、`/share` で送った transcript は、学習設定に関係なく 5 年保持される。
- テレメトリ等は別途 `DISABLE_TELEMETRY`、`DISABLE_ERROR_REPORTING`、`DISABLE_FEEDBACK_COMMAND` で停止する。
- 秘密情報をプロンプトに入れない対策は、学習設定とは独立して必要。

## 補足: 本書の限界

- 事件①②は advisory で確認したが、バージョンごとの修正状況は公式 advisory で再確認すること。
- `sandbox.credentials` と Read deny の連動(Bash 経由の読み取りが止まるか)は公式の記述からの推論を含む。必ず自環境で検証する。
- 設定キーと機能の提供バージョンは変わりうる。最新は公式ドキュメントを参照する。

参照:
- https://code.claude.com/docs/en/security
- https://code.claude.com/docs/en/sandboxing
- https://code.claude.com/docs/en/permissions
- https://code.claude.com/docs/en/hooks
- https://code.claude.com/docs/en/permission-modes
- https://code.claude.com/docs/en/data-usage
- https://github.com/advisories/GHSA-jh7p-qr78-84p7
- https://github.com/advisories/GHSA-vp62-r36r-9xqp
