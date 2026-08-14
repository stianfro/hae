import Foundation
import Testing

@testable import HaeCore

@Test
func sha256AndVerification() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try Data("abc".utf8).write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }

  let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  #expect(try HashVerifier.sha256(of: url) == expected)
  try HashVerifier.verify(url, expectedSHA256: expected)
  #expect(throws: HashVerifierError.self) {
    try HashVerifier.verify(url, expectedSHA256: String(repeating: "0", count: 64))
  }
}
