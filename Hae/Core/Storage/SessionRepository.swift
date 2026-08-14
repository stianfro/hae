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

public struct StoredSession: Equatable, Sendable {
  public let manifest: SessionManifest
  public let paths: SessionPaths

  public init(manifest: SessionManifest, paths: SessionPaths) {
    self.manifest = manifest
    self.paths = paths
  }
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
    let sessions = support.appendingPathComponent("Hae/Sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    return sessions
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

  public func recoverSessions(now: Date = Date()) throws -> [StoredSession] {
    try FileManager.default.createDirectory(
      at: sessionsDirectory,
      withIntermediateDirectories: true
    )
    let properties: Set<URLResourceKey> = [.isDirectoryKey]
    let directories = try FileManager.default.contentsOfDirectory(
      at: sessionsDirectory,
      includingPropertiesForKeys: Array(properties),
      options: [.skipsHiddenFiles]
    )

    var sessions: [StoredSession] = []
    for directory in directories {
      guard
        (try? directory.resourceValues(forKeys: properties).isDirectory) == true
      else { continue }

      let paths = SessionPaths(directory: directory)
      guard var manifest = try? load(paths: paths) else { continue }
      let frameCount = try Self.completePCMFrameCount(at: paths.mixedPCM, repairTrailingByte: true)

      switch manifest.status {
      case .recording:
        manifest.durationFrames = frameCount
        manifest.stoppedAt = now
        manifest.failure = SessionFailure(
          stage: "recovery",
          message: "The application stopped before the recording was closed."
        )
        try manifest.transition(to: .interrupted)
        try save(manifest, paths: paths)
      case .finalizing:
        manifest.durationFrames = frameCount
        manifest.failure = SessionFailure(
          stage: "recovery",
          message: "The application stopped before transcription completed."
        )
        try manifest.transition(to: .interrupted)
        try save(manifest, paths: paths)
      case .captured, .interrupted, .failed:
        if frameCount > 0, manifest.durationFrames != frameCount {
          manifest.durationFrames = frameCount
          try save(manifest, paths: paths)
        }
      case .completed:
        break
      }
      sessions.append(StoredSession(manifest: manifest, paths: paths))
    }

    return sessions.sorted { left, right in
      left.manifest.createdAt > right.manifest.createdAt
    }
  }

  public static func completePCMFrameCount(
    at url: URL,
    repairTrailingByte: Bool
  ) throws -> Int64 {
    guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let fileSize = attributes[.size] as? NSNumber else {
      throw CocoaError(.fileReadUnknown)
    }
    let byteCount = fileSize.int64Value
    let completeByteCount = byteCount - byteCount % Int64(MemoryLayout<Int16>.size)
    if repairTrailingByte, completeByteCount != byteCount {
      let handle = try FileHandle(forWritingTo: url)
      try handle.truncate(atOffset: UInt64(completeByteCount))
      try handle.close()
    }
    return completeByteCount / Int64(MemoryLayout<Int16>.size)
  }

  private static func defaultTitle(date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return "Meeting \(formatter.string(from: date))"
  }
}
