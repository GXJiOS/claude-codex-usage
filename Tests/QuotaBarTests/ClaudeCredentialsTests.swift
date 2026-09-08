import XCTest
import Security
import os
@testable import QuotaBar

final class ClaudeCredentialsTests: XCTestCase {
    private final class Fixture: @unchecked Sendable {
        struct State {
            var token = "fixture-a"
            var failProfile = false
            var profileCalls = 0
            var credentialError: OSStatus?
        }
        let state = OSAllocatedUnfairLock(initialState: State())

        func provider(readCredentials: (@Sendable () throws -> Data)? = nil) -> ClaudeProvider {
            let reader: @Sendable () throws -> Data = readCredentials ?? { [self] in
                try state.withLock { state in
                    if let error = state.credentialError { throw KeychainError(status: error) }
                    return try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
                        "accessToken": state.token,
                        "subscriptionType": state.token.hasPrefix("fixture-a") ? "team" : "pro",
                        "expiresAt": 4_102_444_800_000
                    ]])
                }
            }
            return ClaudeProvider(readCredentials: reader, get: { [self] url, headers in
                let isA = headers["Authorization"]?.hasPrefix("Bearer fixture-a") == true
                if url.path.hasSuffix("/profile") {
                    let fail = state.withLock { state in
                        state.profileCalls += 1
                        return state.failProfile
                    }
                    if fail { return HTTP.Response(status: 503, data: Data()) }
                    return HTTP.Response(status: 200, data: try JSONSerialization.data(withJSONObject: [
                        "account": ["email": isA ? "a@example.test" : "b@example.test"]
                    ]))
                }
                return HTTP.Response(status: 200, data: try JSONSerialization.data(withJSONObject: [
                    "five_hour": ["utilization": isA ? 21 : 62],
                    "seven_day": ["utilization": isA ? 35 : 73]
                ]))
            }, tokensToday: { 0 })
        }
    }

    func testAccountSwitchUpdatesEmailPlanAndUsageTogether() async throws {
        let fixture = Fixture()
        let provider = fixture.provider()
        let a = try await provider.fetch()
        XCTAssertEqual(a.accountLabel, "a@example.test")
        XCTAssertEqual(a.planLabel, "Team")
        XCTAssertEqual(a.session?.usedPercent, 21)

        fixture.state.withLock { $0.token = "fixture-b" }
        let b = try await provider.fetch()
        XCTAssertEqual(b.accountLabel, "b@example.test")
        XCTAssertEqual(b.planLabel, "Pro")
        XCTAssertEqual(b.session?.usedPercent, 62)
        XCTAssertEqual(b.weekly?.usedPercent, 73)
        XCTAssertEqual(fixture.state.withLock { $0.profileCalls }, 2)
    }

    func testTokenRotationRefreshesProfileAndStableTokenUsesCache() async throws {
        let fixture = Fixture()
        let provider = fixture.provider()
        _ = try await provider.fetch()
        _ = try await provider.fetch()
        XCTAssertEqual(fixture.state.withLock { $0.profileCalls }, 1)
        fixture.state.withLock { $0.token = "fixture-a-renewed" }
        let renewed = try await provider.fetch()
        XCTAssertEqual(renewed.accountLabel, "a@example.test")
        XCTAssertEqual(fixture.state.withLock { $0.profileCalls }, 2)
    }

    func testFailedNewAccountProfileDoesNotReusePreviousEmailAndRetries() async throws {
        let fixture = Fixture()
        let provider = fixture.provider()
        _ = try await provider.fetch()
        fixture.state.withLock { $0.token = "fixture-b"; $0.failProfile = true }
        let failedProfile = try await provider.fetch()
        XCTAssertNil(failedProfile.accountLabel)
        XCTAssertEqual(failedProfile.planLabel, "Pro")
        XCTAssertEqual(failedProfile.session?.usedPercent, 62)
        fixture.state.withLock { $0.failProfile = false }
        let recovered = try await provider.fetch()
        XCTAssertEqual(recovered.accountLabel, "b@example.test")
    }

    func testMissingCredentialPreservesLoginError() async throws {
        let fixture = Fixture()
        fixture.state.withLock { $0.credentialError = errSecItemNotFound }
        do {
            _ = try await fixture.provider().fetch()
            XCTFail("Missing credentials must fail")
        } catch ProviderError.notLoggedIn { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.state.withLock { $0.profileCalls }, 0)
    }

    func testSecurityExitStatusMappingAndFailedOutputIsDiscarded() {
        let sensitive = Data("dummy credential must not appear in an error".utf8)
        for status in [errSecItemNotFound, errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
            XCTAssertThrowsError(try Keychain.password(exitCode: Int32(UInt8(truncatingIfNeeded: status)), data: sensitive)) { error in
                XCTAssertEqual((error as? KeychainError)?.status, status)
                XCTAssertFalse(error.localizedDescription.contains("dummy credential"))
            }
        }
        XCTAssertThrowsError(try Keychain.password(exitCode: 0, data: Data()))
        XCTAssertThrowsError(try Keychain.password(exitCode: 1, data: sensitive))
    }

    func testCommandDrainsOutputLargerThanPipeBuffer() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data(repeating: 97, count: 256 * 1024)
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.arguments = [file.path]
        let result = try Keychain.run(process, timeout: 3)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.data, payload)
    }

    func testCommandTimeoutStopsTheProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let start = Date()
        XCTAssertThrowsError(try Keychain.run(process, timeout: 0.1)) { error in
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testCommandCapsOutputAndStopsTheProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        process.arguments = ["dummy"]
        XCTAssertThrowsError(try Keychain.run(process, timeout: 3, outputLimit: 32 * 1024)) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecDecode)
        }
        XCTAssertFalse(process.isRunning)
    }

    func testSystemReaderTracksCLIUpdatesAndAccountSwitch() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_KEYCHAIN_INTEGRATION"] == "1" else {
            throw XCTSkip("Set QUOTABAR_KEYCHAIN_INTEGRATION=1 to test disposable login-keychain fixtures")
        }
        let service = "com.gcdm.quotabar.credentials-test.\(UUID().uuidString)"
        let account = "dummy-fixture"
        func security(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = arguments
            return try Keychain.run(process, timeout: 5).exitCode
        }
        defer {
            XCTAssertEqual(try security(["delete-generic-password", "-s", service, "-a", account]), 0)
        }
        func writeFixture(token: String, plan: String) throws {
            let json = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
                "accessToken": token, "subscriptionType": plan, "expiresAt": 4_102_444_800_000
            ]])
            let hex = json.map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(try security(["add-generic-password", "-U", "-s", service,
                                         "-a", account, "-X", hex]), 0)
        }
        let fixture = Fixture()
        let provider = fixture.provider {
            try Keychain.genericPassword(service: service, account: account)
        }
        for rotation in 1...5 {
            try writeFixture(token: "fixture-a-\(rotation)", plan: "team")
            for _ in 0..<2 {
                let a = try await provider.fetch()
                XCTAssertEqual(a.accountLabel, "a@example.test")
                XCTAssertEqual(a.planLabel, "Team")
                XCTAssertEqual(a.session?.usedPercent, 21)
            }
        }
        try writeFixture(token: "fixture-b", plan: "pro")
        let b = try await provider.fetch()
        XCTAssertEqual(b.accountLabel, "b@example.test")
        XCTAssertEqual(b.planLabel, "Pro")
        XCTAssertEqual(b.session?.usedPercent, 62)
        let restarted = fixture.provider {
            try Keychain.genericPassword(service: service, account: account)
        }
        let restored = try await restarted.fetch()
        XCTAssertEqual(restored.accountLabel, "b@example.test")
        XCTAssertEqual(restored.weekly?.usedPercent, 73)
    }
}
