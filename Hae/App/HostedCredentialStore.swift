import Foundation
import Security

protocol HostedCredentialStoring {
  func apiKey(for endpoint: URL) throws -> String?
  func save(apiKey: String, for endpoint: URL) throws
}

struct HostedCredentialStore: HostedCredentialStoring {
  private let service = "no.froystein.hae.hosted-transcription"

  func apiKey(for endpoint: URL) throws -> String? {
    var query = query(for: endpoint)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
      throw CredentialError.invalidData
    }
    return key
  }

  func save(apiKey: String, for endpoint: URL) throws {
    let query = query(for: endpoint)
    if apiKey.isEmpty {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw CredentialError.keychain(status)
      }
      return
    }

    let attributes = [kSecValueData as String: Data(apiKey.utf8)]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = Data(apiKey.utf8)
      item[kSecAttrLabel as String] = "Hæ? hosted transcription"
      item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      item[kSecAttrSynchronizable as String] = false
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw CredentialError.keychain(addStatus) }
    } else if status != errSecSuccess {
      throw CredentialError.keychain(status)
    }
  }

  private func query(for endpoint: URL) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: endpoint.absoluteString,
    ]
  }
}

private enum CredentialError: LocalizedError {
  case keychain(OSStatus)
  case invalidData

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      "Could not access the API key in Keychain (status \(status)). Unlock your login keychain and try again."
    case .invalidData:
      "The saved API key could not be read. Replace it in Transcription settings."
    }
  }
}
