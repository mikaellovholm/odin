import Foundation
import CryptoKit
import LocalAuthentication

enum SSHKeyManager {
    private static let tag = "com.mikaellovholm.odin.ssh.ed25519"
    private static let biometricToggleKey = "ssh.biometricProtected"

    /// Whether the user has opted into biometric protection. When on, the
    /// stored key uses an access control object that requires biometry
    /// (Touch ID / Face ID) for every read.
    static var biometricProtectionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: biometricToggleKey) }
        set { UserDefaults.standard.set(newValue, forKey: biometricToggleKey) }
    }

    /// True when the device exposes a usable biometric sensor we can require.
    static func biometricsAvailable() -> Bool {
        var error: NSError?
        let ctx = LAContext()
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    static func hasKey() -> Bool {
        // Check for presence without triggering a biometric prompt. Setting
        // LAContext.interactionNotAllowed makes the lookup fail with
        // errSecInteractionNotAllowed if the key exists but requires auth,
        // which still tells us the key is there.
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: false,
            kSecUseAuthenticationContext as String: ctx,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
            || status == errSecInteractionNotAllowed
    }

    @discardableResult
    static func generateKey() throws -> Curve25519.Signing.PrivateKey {
        try? deleteKey()
        let privateKey = Curve25519.Signing.PrivateKey()
        try store(privateKey.rawRepresentation,
                  biometric: biometricProtectionEnabled)
        return privateKey
    }

    static func getPrivateKey() throws -> Curve25519.Signing.PrivateKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
        ]
        if biometricProtectionEnabled {
            let ctx = LAContext()
            ctx.localizedReason = "Authenticate to use your SSH key"
            query[kSecUseAuthenticationContext as String] = ctx
        }
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

    /// Re-store the existing key with biometric protection toggled. Used by
    /// the settings UI without forcing the user to regenerate (and re-upload
    /// the public key to GCP).
    static func setBiometricProtection(_ enabled: Bool) throws {
        let key = try getPrivateKey()
        try? deleteKey()
        try store(key.rawRepresentation, biometric: enabled)
        biometricProtectionEnabled = enabled
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

    private static func store(_ data: Data, biometric: Bool) throws {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecValueData as String: data,
        ]
        if biometric {
            var cfError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .biometryCurrentSet,
                &cfError
            ) else {
                let err = cfError?.takeRetainedValue()
                throw KeychainError.accessControlFailed(err.map { CFErrorCopyDescription($0) as String } ?? "unknown")
            }
            attributes[kSecAttrAccessControl as String] = access
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)
        case accessControlFailed(String)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let s): "Failed to save SSH key (OSStatus \(s))"
            case .loadFailed(let s): "Failed to load SSH key (OSStatus \(s))"
            case .deleteFailed(let s): "Failed to delete SSH key (OSStatus \(s))"
            case .accessControlFailed(let msg): "Failed to set biometric protection: \(msg)"
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
