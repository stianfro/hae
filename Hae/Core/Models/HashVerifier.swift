import CryptoKit
import Foundation

public enum HashVerifierError: Error, Equatable, LocalizedError, Sendable {
  case unreadableFile(String)
  case mismatch(expected: String, actual: String)

  public var errorDescription: String? {
    switch self {
    case .unreadableFile(let path):
      "Could not read file at \(path)."
    case .mismatch(let expected, let actual):
      "SHA-256 mismatch. Expected \(expected), got \(actual)."
    }
  }
}

public enum HashVerifier {
  public static func sha256(of fileURL: URL) throws -> String {
    guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
      throw HashVerifierError.unreadableFile(fileURL.path)
    }
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public static func verify(_ fileURL: URL, expectedSHA256: String) throws {
    let actual = try sha256(of: fileURL)
    let expected = expectedSHA256.lowercased()
    guard actual == expected else {
      throw HashVerifierError.mismatch(expected: expected, actual: actual)
    }
  }
}
