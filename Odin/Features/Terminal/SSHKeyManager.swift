import Foundation
import CryptoKit

enum SSHKeyManager {
    private static let tag = "com.mikaellovholm.odin.ssh.ed25519"

    static func hasKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: false,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func generateKey() throws -> Curve25519.Signing.PrivateKey {
        try? deleteKey()
        let privateKey = Curve25519.Signing.PrivateKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecValueData as String: privateKey.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
        return privateKey
    }

    static func getPrivateKey() throws -> Curve25519.Signing.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.loadFailed(status)
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    static func getPublicKeyOpenSSH() throws -> String {
        let privateKey = try getPrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation

        // OpenSSH wire format: ssh-ed25519 <base64(len+"ssh-ed25519"+len+pubkey32)>
        let keyType = "ssh-ed25519"
        let keyTypeData = keyType.data(using: .utf8)!

        var wireData = Data()
        wireData.appendSSHLength(UInt32(keyTypeData.count))
        wireData.append(keyTypeData)
        wireData.appendSSHLength(UInt32(publicKey.count))
        wireData.append(publicKey)

        let encoded = wireData.base64EncodedString()
        return "\(keyType) \(encoded) odin@device"
    }

    static func deleteKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let s): "Failed to save SSH key (OSStatus \(s))"
            case .loadFailed(let s): "Failed to load SSH key (OSStatus \(s))"
            case .deleteFailed(let s): "Failed to delete SSH key (OSStatus \(s))"
            }
        }
    }
}

private extension Data {
    mutating func appendSSHLength(_ length: UInt32) {
        var bigEndian = length.bigEndian
        append(Data(bytes: &bigEndian, count: 4))
    }
}
