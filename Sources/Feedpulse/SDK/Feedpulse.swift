import Foundation

/// 公開 API の入口。`configure` で SDK を初期化し、`client` から使う。
/// 該当箇所ピッカー（`pickTarget`）は `Picker/FeedpulsePicker.swift` の拡張。
public enum Feedpulse {
    @MainActor private static var shared: FeedpulseClient?

    /// SDK を初期化して `FeedpulseClient` を返す。アプリ起動時に 1 回呼ぶ。2 回目以降は新しい設定で作り直す。
    ///
    /// - Parameters:
    ///   - publicKey: プロジェクトの公開鍵（`pk_...`）。
    ///   - baseURL: ingest の URL。既定は本番。
    ///   - appId: 登録した bundle ID。省略時は `Bundle.main.bundleIdentifier`。
    ///   - attestation: アプリ証明の提供元。省略時は App Attest（実機のみ）。ローカル開発サーバーでは `DevInsecureAttestationProvider()`。
    @MainActor
    @discardableResult
    public static func configure(
        publicKey: String,
        baseURL: URL = FeedpulseConfiguration.productionBaseURL,
        appId: String? = nil,
        attestation: FeedpulseAttestationProvider? = nil
    ) -> FeedpulseClient {
        configure(FeedpulseConfiguration(publicKey: publicKey, baseURL: baseURL, appId: appId, attestation: attestation))
    }

    /// 詳細な設定（再送回数・キャッシュ先など）を渡す版。
    @MainActor
    @discardableResult
    public static func configure(_ configuration: FeedpulseConfiguration) -> FeedpulseClient {
        let client = FeedpulseClient(configuration: configuration)
        shared = client
        return client
    }

    /// `configure` が返したクライアント。`configure` 前に呼ぶとクラッシュする。
    @MainActor
    public static var client: FeedpulseClient {
        guard let shared else {
            preconditionFailure("Feedpulse.configure(publicKey:) を先に呼んでください")
        }
        return shared
    }

    /// `client.identify(_:)` の短縮形。
    @MainActor
    public static func identify(_ token: String?) { client.identify(token) }
}
