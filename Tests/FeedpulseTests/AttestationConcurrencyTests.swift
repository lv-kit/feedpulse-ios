import XCTest
@testable import Feedpulse

/// 鍵の受理・拒否・再生成が並行しても、古い処理が新しい鍵を消さないことを確認する。
final class AttestationConcurrencyTests: XCTestCase {
    private let challenge = String(repeating: "A", count: 48)

    /// `generateAssertion` を呼び出し側が再開するまで保留できる偽物。
    private final class SuspendingService: AppAttestServing, @unchecked Sendable {
        var isSupported = true
        private let lock = NSLock()
        private var entered: CheckedContinuation<Void, Never>?
        private var resume: CheckedContinuation<Void, Never>?

        func generateKey() async throws -> String { "ZnJlc2g=" }
        func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("a".utf8) }
        func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock(); resume = c; let e = entered; entered = nil; lock.unlock()
                e?.resume()
            }
            throw NSError(domain: "DCErrorDomain", code: 3)
        }
        func waitUntilSuspended() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if resume != nil { lock.unlock(); c.resume() } else { entered = c; lock.unlock() }
            }
        }
        func release() { lock.lock(); let r = resume; resume = nil; lock.unlock(); r?.resume() }
    }

    func testRejectedAttestationOfOldKeyKeepsNewKey() async {
        let store = InMemoryKeyStore()
        let p = AppAttestProvider(service: FakeAppAttest(), keyStore: store)
        let old = FeedpulseAttestationPayload.attestation(keyId: "b2xk", attestation: "YQ==")
        let new = FeedpulseAttestationPayload.attestation(keyId: "bmV3", attestation: "YQ==")
        await p.accepted(new)
        await p.rejected(old)
        XCTAssertEqual(store.load(), "bmV3")
    }

    func testRejectedAssertionOfOldKeyKeepsNewKey() async {
        let store = InMemoryKeyStore("b2xk")
        let p = AppAttestProvider(service: FakeAppAttest(), keyStore: store)
        await p.accepted(.attestation(keyId: "bmV3", attestation: "YQ=="))
        await p.rejected(.assertion(keyId: "b2xk", assertion: "YQ=="))
        XCTAssertEqual(store.load(), "bmV3")
    }

    func testRejectedPayloadOfCurrentKeyDeletesIt() async {
        let store = InMemoryKeyStore("b2xk")
        let p = AppAttestProvider(service: FakeAppAttest(), keyStore: store)
        await p.rejected(.assertion(keyId: "b2xk", assertion: "YQ=="))
        XCTAssertNil(store.load())
    }

    func testRejectedDevInsecureKeepsKey() async {
        let store = InMemoryKeyStore("b2xk")
        let p = AppAttestProvider(service: FakeAppAttest(), keyStore: store)
        await p.rejected(.devInsecure)
        XCTAssertEqual(store.load(), "b2xk")
    }

    func testRejectedOldKeyAlsoKeepsNewKeyInMemoryWhenKeychainWriteFailed() async throws {
        // Keychain に書けない環境（save が効かない）でも、メモリ上の新しい鍵は残る。
        final class NoopStore: FeedpulseKeyStore, @unchecked Sendable {
            func load() -> String? { nil }
            func save(_ keyId: String) {}
            func delete() {}
        }
        let service = FakeAppAttest()
        let p = AppAttestProvider(service: service, keyStore: NoopStore())
        await p.accepted(.attestation(keyId: "bmV3", attestation: "YQ=="))
        await p.rejected(.attestation(keyId: "b2xk", attestation: "YQ=="))
        let payload = try await p.payload(forChallenge: challenge)
        XCTAssertEqual(payload, .assertion(keyId: "bmV3", assertion: "YXNzZXJ0aW9u"))
    }

    func testAssertionFailureOfOldKeyKeepsNewKeyAcceptedMeanwhile() async throws {
        let store = InMemoryKeyStore("b2xk")
        let service = SuspendingService()
        let p = AppAttestProvider(service: service, keyStore: store)
        let pending = Task { try await p.payload(forChallenge: challenge) }
        await service.waitUntilSuspended()          // 旧鍵の assertion を保留
        await p.accepted(.attestation(keyId: "bmV3", attestation: "YQ=="))  // その間に新鍵を受理
        service.release()                            // 旧鍵の assertion が失敗
        _ = try await pending.value
        XCTAssertEqual(store.load(), "bmV3")
    }
}
