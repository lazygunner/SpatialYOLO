//
//  LocalUserIdentity.swift
//  SpatialYOLO
//
//  使用 Keychain 持久化一个稳定的本地 UUID，作为云端记忆同步的用户唯一 ID
//

import Foundation
import Security

enum LocalUserIdentity {
    private static let service = "com.darkstring.SpatialYOLO"
    private static let account = "cloudMemoryUserID"

    static func currentUserID() -> String {
        if let existing = loadUserID() {
            return existing
        }

        let newID = UUID().uuidString.lowercased()
        saveUserID(newID)
        return newID
    }

    private static func loadUserID() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func saveUserID(_ userID: String) {
        let data = Data(userID.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData as String] = data
            insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insertQuery as CFDictionary, nil)
        }
    }
}
