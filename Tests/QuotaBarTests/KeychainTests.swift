import XCTest
import Security
@testable import QuotaBar

final class KeychainTests: XCTestCase {
    func testCredentialReadsDisableInteractionBeforeSearching() throws {
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(true), errSecSuccess)
        XCTAssertThrowsError(try Keychain.genericPassword(service: "com.gcdm.quotabar.missing.\(UUID())"))
        var allowed = DarwinBoolean(true)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
        XCTAssertFalse(allowed.boolValue, "Every credential read must enforce silent access.")
    }

    func testAuthorizedCredentialsRemainReadable() throws {
        try requireKeychainIntegration()
        try enforceSilentAccess()
        let fixture = try Fixture(allowCurrentProcess: true)
        defer { fixture.remove() }
        XCTAssertEqual(try Keychain.genericPassword(service: fixture.service), Fixture.value)
    }

    @MainActor
    func testAutomaticAndManualRefreshReturnWithoutAuthorizationUI() async throws {
        try requireKeychainIntegration()
        try enforceSilentAccess()
        let fixture = try Fixture(allowCurrentProcess: false)
        defer { fixture.remove() }
        let store = UsageStore(providers: [FixtureProvider(service: fixture.service)])

        for force in [false, true, false, true] {
            let started = Date()
            await store.refresh(force: force)
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
            XCTAssertEqual(store.statuses[.claude]?.errorMessage, "Connection needs attention")
            XCTAssertFalse(store.statuses[.claude]?.isLoading ?? true)
            XCTAssertNotNil(store.lastRefresh)
            var allowed = DarwinBoolean(true)
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
            XCTAssertFalse(allowed.boolValue)
        }
    }

    private func requireKeychainIntegration() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QUOTABAR_KEYCHAIN_INTEGRATION"] == "1",
                          "Set QUOTABAR_KEYCHAIN_INTEGRATION=1 to use temporary, non-sensitive Keychain fixtures.")
    }

    private func enforceSilentAccess() throws {
        _ = try? Keychain.genericPassword(service: "com.gcdm.quotabar.missing.\(UUID())")
        var allowed = DarwinBoolean(true)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
        guard !allowed.boolValue else {
            XCTFail("Silent access must be active before testing an unauthorized credential.")
            throw KeychainError(status: errSecInteractionNotAllowed)
        }
    }

    private struct FixtureProvider: UsageProvider {
        let kind: ProviderKind = .claude
        let service: String

        func fetch() async throws -> UsageSnapshot {
            _ = try Keychain.genericPassword(service: service)
            throw ProviderError.decoding("The unauthorized fixture unexpectedly became readable.")
        }
    }

    private final class Fixture {
        static let value = Data("QuotaBar non-sensitive test fixture".utf8)
        let service = "com.gcdm.quotabar.keychain-test.\(UUID())"
        private let account = "quotabar-test-fixture"

        init(allowCurrentProcess: Bool) throws {
            var security: SecTrustedApplication?
            try Self.check(SecTrustedApplicationCreateFromPath("/usr/bin/security", &security))
            var trusted = [try XCTUnwrap(security)]
            if allowCurrentProcess {
                var current: SecTrustedApplication?
                try Self.check(SecTrustedApplicationCreateFromPath(nil, &current))
                trusted.append(try XCTUnwrap(current))
            }
            var access: SecAccess?
            try Self.check(SecAccessCreate("QuotaBar temporary test credential" as CFString,
                                           trusted as CFArray, &access))
            var query = selector
            query[kSecValueData as String] = Self.value
            query[kSecAttrAccess as String] = try XCTUnwrap(access)
            try Self.check(SecItemAdd(query as CFDictionary, nil))
        }

        private var selector: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: service,
             kSecAttrAccount as String: account]
        }

        func remove() {
            // The fixture explicitly trusts this tool for cleanup of its unique service.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["delete-generic-password", "-s", service, "-a", account]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, "Fixture cleanup failed: \(service)")
            } catch { XCTFail("Fixture cleanup failed: \(error)") }
        }

        private static func check(_ status: OSStatus) throws {
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }
}
