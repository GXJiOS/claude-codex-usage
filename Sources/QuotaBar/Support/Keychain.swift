import Foundation
import LocalAuthentication
import Security

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            return "Connection needs attention"
        }
        return (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

enum Keychain {
    /// Reads a generic-password item silently and reports unavailable access as an error.
    static func genericPassword(service: String) throws -> Data {
        // Legacy login-keychain items require the process-wide interaction setting.
        // QuotaBar keeps it disabled for automatic, manual, and diagnostic reads.
        let interactionStatus = SecKeychainSetUserInteractionAllowed(false)
        guard interactionStatus == errSecSuccess else { throw KeychainError(status: interactionStatus) }

        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data else { throw KeychainError(status: errSecDecode) }
        return data
    }
}
