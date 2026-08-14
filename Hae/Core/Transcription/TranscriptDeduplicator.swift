import Foundation

public enum TranscriptDeduplicator {
  public static func removingOverlap(
    previousText: String,
    newText: String,
    tokenWindow: Int = 24
  ) -> String {
    let previous = tokens(in: previousText)
    let incoming = tokens(in: newText)
    let maximum = min(tokenWindow, previous.count, incoming.count)
    guard maximum > 0 else { return newText.trimmingCharacters(in: .whitespaces) }

    var duplicateCount = 0
    for count in stride(from: maximum, through: 1, by: -1) {
      if previous.suffix(count).map(\.normalized) == incoming.prefix(count).map(\.normalized) {
        duplicateCount = count
        break
      }
    }
    guard duplicateCount > 0 else { return newText.trimmingCharacters(in: .whitespaces) }
    return incoming.dropFirst(duplicateCount).map(\.original).joined(separator: " ")
  }

  private struct Token {
    let original: String
    let normalized: String
  }

  private static func tokens(in text: String) -> [Token] {
    text.split(whereSeparator: \.isWhitespace).map { substring in
      let original = String(substring)
      let normalized =
        original
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .trimmingCharacters(in: .punctuationCharacters)
      return Token(original: original, normalized: normalized)
    }
  }
}
