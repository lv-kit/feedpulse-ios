import Foundation
import Combine

/// Feedpulse のヘッドレスクライアント。SwiftUI からは `@ObservedObject` / `@StateObject` / `@EnvironmentObject` で使える。
///
/// ```swift
/// let client = Feedpulse.configure(publicKey: "pk_...")
/// try await client.refresh()
/// let form = client.forms[0]
/// let result = form.validate(["title": "ログインできない"])
/// let receipt = try await client.submit(FeedpulseSubmission(formId: form.id, values: result.cleaned))
/// ```
@MainActor
public final class FeedpulseClient: ObservableObject {
    /// 項目定義（キャッシュを含む）。`refresh()` で更新される。
    @Published public private(set) var forms: [FeedpulseForm] = []
    @Published public private(set) var widget: [String: FeedpulseJSONValue] = [:]
    @Published public private(set) var isRefreshing = false
    /// `forms` が通信に失敗したときの前回値か。
    @Published public private(set) var isStale = false
    /// 直近の `refresh()` が失敗した理由（成功すると nil）。
    @Published public private(set) var lastRefreshError: FeedpulseError?
    @Published public private(set) var isSubmitting = false
    /// `identify(_:)` でトークンを渡してあるか。
    @Published public private(set) var isIdentified = false

    private let engine: FeedpulseEngine
    private var identityToken: String?
    private var submittingCount = 0
    private var refreshingCount = 0

    public convenience init(configuration: FeedpulseConfiguration) {
        self.init(engine: FeedpulseEngine(config: configuration))
    }

    init(engine: FeedpulseEngine) {
        self.engine = engine
        Task { [weak self] in await self?.loadCachedForms() }
    }

    private func loadCachedForms() async {
        guard forms.isEmpty, let cached = await engine.cachedConfig else { return }
        forms = cached.forms
        widget = cached.widget
    }

    // MARK: 項目定義

    /// 項目定義を取得して `forms` を更新する。鮮度内のキャッシュがあれば通信しない（`force: true` で必ず通信）。
    /// 通信に失敗しても前回値があれば前回値を返し（`isStale == true`、`lastRefreshError` に理由）、前回値が無いときだけ投げる。
    @discardableResult
    public func refresh(force: Bool = false) async throws -> [FeedpulseForm] {
        refreshingCount += 1
        isRefreshing = true
        defer {
            refreshingCount -= 1
            isRefreshing = refreshingCount > 0
        }
        do {
            let result = try await engine.loadConfig(force: force)
            forms = result.config.forms
            widget = result.config.widget
            isStale = result.isStale
            lastRefreshError = result.error
            return result.config.forms
        } catch let error as FeedpulseError {
            lastRefreshError = error
            throw error
        }
    }

    public func form(id: String) -> FeedpulseForm? { forms.first { $0.id == id } }
    public func form(slug: String) -> FeedpulseForm? { forms.first { $0.slug == slug } }

    // MARK: 身元確認

    /// 顧客のバックエンドが `sk_` で署名した身元確認トークン（JWT）を渡す。以降の送信の `context.identity` にそのまま載る。
    /// SDK は検証しない。トークンはメモリにだけ保持し、永続化しない。`nil` か空文字で解除する。
    /// 期限切れ（発行から 1 時間）で送信が `identity_invalid` になったら、新しいトークンを渡し直す。
    public func identify(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        identityToken = (trimmed?.isEmpty ?? true) ? nil : trimmed
        isIdentified = identityToken != nil
    }

    // MARK: 送信

    /// 送信する。検証 → セッション取得 → `POST /v1/submit`。
    ///
    /// - 項目定義に照らしてクライアント側で検証し、失敗なら通信せず `FeedpulseError.validation` を投げる。
    /// - ネットワークエラー・429・5xx は同じ冪等キーで自動再送する（429 は `Retry-After` を尊重）。
    /// - それでも失敗したら、**同じ `FeedpulseSubmission`（同じ冪等キー）で再度呼ぶ**と二重に保存されない。
    @discardableResult
    public func submit(_ submission: FeedpulseSubmission) async throws -> FeedpulseReceipt {
        guard FeedpulseSubmission.isValidIdempotencyKey(submission.idempotencyKey) else {
            throw FeedpulseError.invalidArgument("idempotencyKey must match ^[A-Za-z0-9_-]{16,64}$")
        }
        for (key, value) in submission.custom {
            if case .number(let n) = value, !n.isFinite { throw FeedpulseError.invalidArgument("custom[\(key)] is not finite") }
        }
        submittingCount += 1
        isSubmitting = true
        defer {
            submittingCount -= 1
            isSubmitting = submittingCount > 0
        }
        let form = try await engine.form(id: submission.formId)
        let validation = form.validate(submission.values)
        guard validation.isValid else { throw FeedpulseError.validation(validation.errors) }
        return try await engine.submit(submission, fields: validation.cleaned, identity: identityToken)
    }
}
