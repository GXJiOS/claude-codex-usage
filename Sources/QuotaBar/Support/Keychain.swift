import Foundation
import Security

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

enum Keychain {
    /// Reads the secret of a generic-password item by service name.
    /// macOS asks the user for permission the first time another app touches the item.
    static func genericPassword(service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data else { throw KeychainError(status: errSecDecode) }
        return data
    }
}
