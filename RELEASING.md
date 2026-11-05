# リリース手順

1. `Feedpulse.podspec` の `version` と `CHANGELOG.md` に新バージョンの節を追加する。
2. CI（ビルドとテスト）が通ることを確認し、PR で `main` に取り込む。
3. `main` で `git tag X.Y.Z` を打って push する（SwiftPM はタグがバージョンになる）。
4. GitHub の Releases でタグからリリースノートを作る（メンテナが実行する）。
