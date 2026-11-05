import Foundation
import CryptoKit
#if canImport(DeviceCheck)
import DeviceCheck
#endif
#if canImport(Security)
import Security
#endif

/// `POST /v1/native/session` の `attestation` に載せる証明。
public enum FeedpulseAttestationPayload: Equatable, Sendable {
    /// 鍵を作った直後の 1 回だけ。`keyId` / `attestation` は base64（標準）。
    case attestation(keyId: String, attestation: String)
    /// 登録済みの鍵で作る。以降はこちら。
    case assertion(keyId: String, assertion: String)
    /// ローカル開発専用（サーバー側の `NATIVE_ATTEST_INSECURE_DEV=true` のときだけ受理される）。
    case devInsecure

    var json: [String: String] {
        switch self {
        case .attestation(let keyId, let attestation):
            return ["type": "app_attest_attestation", "keyId": keyId, "attestation": attestation]
        case .assertion(let keyId, let assertion):
            return ["type": "app_attest_assertion", "keyId": keyId, "assertion": assertion]
        case .devInsecure:
            return ["type": "dev_insecure"]
        }
    }

    var isAssertion: Bool {
        if case .assertion = self { return true }
        return false
    }
}

/// アプリ証明の提供元。本番は `AppAttestProvider`。単体テストでは差し替える。
public protocol FeedpulseAttestationProvider: Sendable {
    /// サーバーが発行した `challenge` に対する証明を作る。
    func payload(forChallenge challenge: String) async throws -> FeedpulseAttestationPayload
    /// サーバーがこの証明を受理した。鍵を使い続けてよい。
    func accepted(_ payload: FeedpulseAttestationPayload) async
    /// サーバーが証明を拒否した（`attestation_failed`）。保存している鍵があれば捨て、次回は鍵を作り直す。
    func rejected(_ payload: FeedpulseAttestationPayload) async
}

/// ローカル開発サーバー専用。本番では必ず拒否される。
public struct DevInsecureAttestationProvider: FeedpulseAttestationProvider {
    public init() {}
    public func payload(forChallenge challenge: String) async throws -> FeedpulseAttestationPayload { .devInsecure }
    public func accepted(_ payload: FeedpulseAttestationPayload) async {}
    public func rejected(_ payload: FeedpulseAttestationPayload) async {}
}

// MARK: - App Attest

/// `DCAppAttestService` の抽象。単体テストでは偽物を渡す。
public protocol AppAttestServing: Sendable {
    var isSupported: Bool { get }
    /// 新しい鍵を作り、`keyId`（base64）を返す。
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// 端末鍵の `keyId` の保存先。
public protocol FeedpulseKeyStore: Sendable {
    func load() -> String?
    func save(_ keyId: String)
    func delete()
}

/// 本番用の App Attest。保存した `keyId` があれば assertion、無ければ鍵を作って attestation を出す。
///
/// 鍵は attestation をサーバーが受理した後で初めて保存する（受理前に保存すると、未登録の鍵で assertion を送り続けてしまう）。
public final class AppAttestProvider: FeedpulseAttestationProvider, @unchecked Sendable {
    private let service: AppAttestServing
    private let keyStore: FeedpulseKeyStore

    public init(service: AppAttestServing, keyStore: FeedpulseKeyStore) {
        self.service = service
        self.keyStore = keyStore
    }

    /// `DCAppAttestService` と Keychain を使う標準構成。
    public static func system(publicKey: String, appId: String) -> AppAttestProvider {
        AppAttestProvider(service: SystemAppAttestService(), keyStore: KeychainKeyStore(publicKey: publicKey, appId: appId))
    }

    public func payload(forChallenge challenge: String) async throws -> FeedpulseAttestationPayload {
        guard service.isSupported else { throw FeedpulseError.attestationUnsupported }
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        do {
            if let keyId = keyStore.load() {
                let assertion = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
                return .assertion(keyId: keyId, assertion: assertion.base64EncodedString())
            }
            let keyId = try await service.generateKey()
            let attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
            return .attestation(keyId: keyId, attestation: attestation.base64EncodedString())
        } catch let error as FeedpulseError {
            throw error
        } catch {
            // 保存済みの鍵が端末側で無効になっていることもある（OS 復元など）。次回は作り直す。
            if keyStore.load() != nil { keyStore.delete() }
            throw FeedpulseError.attestationUnavailable(String(describing: error))
        }
    }

    public func accepted(_ payload: FeedpulseAttestationPayload) async {
        if case .attestation(let keyId, _) = payload { keyStore.save(keyId) }
    }

    public func rejected(_ payload: FeedpulseAttestationPayload) async {
        keyStore.delete()
    }
}

#if canImport(DeviceCheck)
/// `DCAppAttestService.shared` を使う実装。**実機でのみ動く**（シミュレーターは `isSupported == false`）。
public struct SystemAppAttestService: AppAttestServing {
    public init() {}

    public var isSupported: Bool { DCAppAttestService.shared.isSupported }

    public func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    public func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }

    public func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}
#else
public struct SystemAppAttestService: AppAttestServing {
    public init() {}
    public var isSupported: Bool { false }
    public func generateKey() async throws -> String { throw FeedpulseError.attestationUnsupported }
    public func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { throw FeedpulseError.attestationUnsupported }
    public func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { throw FeedpulseError.attestationUnsupported }
}
#endif

// MARK: - 鍵の保存先

/// メモリ上だけの保存先（テスト・一時利用向け。アプリの再起動で失われる）。
public final class InMemoryKeyStore: FeedpulseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(_ initial: String? = nil) { value = initial }
    public func load() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    public func save(_ keyId: String) { lock.lock(); value = keyId; lock.unlock() }
    public func delete() { lock.lock(); value = nil; lock.unlock() }
}

#if canImport(Security)
/// Keychain に `keyId` を保存する（端末内のみ・初回アンロック後に読める・バックアップに含めない）。
public struct KeychainKeyStore: FeedpulseKeyStore {
    private let service = "xyz.stargazy.feedpulse.appattest"
    private let account: String

    public init(publicKey: String, appId: String) {
        account = "\(appId)|\(publicKey)"
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ keyId: String) {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(keyId.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
#endif
