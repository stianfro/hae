import Foundation

public struct SessionPaths: Equatable, Sendable {
  public let directory: URL

  public var manifest: URL { directory.appendingPathComponent("session.json") }
  public var mixedPCM: URL { directory.appendingPathComponent("audio-mix.pcm16le") }
  public var transcriptJSON: URL { directory.appendingPathComponent("transcript.json") }
  public var transcriptMarkdown: URL { directory.appendingPathComponent("transcript.md") }
  public var transcriptText: URL { directory.appendingPathComponent("transcript.txt") }
  public var transcriptSRT: URL { directory.appendingPathComponent("transcript.srt") }
}

public actor SessionRepository {
  private let sessionsDirectory: URL
  private let encoder: JSONEncoder

  public init(sessionsDirectory: URL) {
    self.sessionsDirectory = sessionsDirectory
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
  }

  public static func applicationSupportSessionsDirectory() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return support.appendingPathComponent("Hae/Sessions", isDirectory: true)
  }

  public func createSession(model: WhisperModelDescriptor, now: Date = Date()) throws
    -> (SessionManifest, SessionPaths)
  {
    let now = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
    let id = UUID()
    let title = Self.defaultTitle(date: now)
    let manifest = SessionManifest(
      id: id,
      title: title,
      createdAt: now,
      startedAt: now,
      model: SessionModelReference(id: model.id, sha256: model.sha256),
      language: model.defaultLanguage
    )
    let paths = SessionPaths(directory: sessionsDirectory.appendingPathComponent(id.uuidString))
    try FileManager.default.createDirectory(
      at: paths.directory,
      withIntermediateDirectories: true
    )
    try save(manifest, paths: paths)
    return (manifest, paths)
  }

  public func save(_ manifest: SessionManifest, paths: SessionPaths) throws {
    try AtomicFileWriter.write(encoder.encode(manifest), to: paths.manifest)
  }

  public func load(paths: SessionPaths) throws -> SessionManifest {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(SessionManifest.self, from: Data(contentsOf: paths.manifest))
  }

  private static func defaultTitle(date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return "Meeting \(formatter.string(from: date))"
  }
}
