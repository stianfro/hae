import Foundation

public enum DiskSpaceStatus: Equatable, Sendable {
  case sufficient(availableBytes: Int64)
  case warning(availableBytes: Int64)
  case critical(availableBytes: Int64)
}

public enum DiskSpacePolicy {
  public static let criticalThresholdBytes: Int64 = 1_000_000_000
  public static let warningThresholdBytes: Int64 = 3_000_000_000

  public static func status(availableBytes: Int64) -> DiskSpaceStatus {
    if availableBytes < criticalThresholdBytes {
      return .critical(availableBytes: availableBytes)
    }
    if availableBytes < warningThresholdBytes {
      return .warning(availableBytes: availableBytes)
    }
    return .sufficient(availableBytes: availableBytes)
  }

  public static func status(for directory: URL) throws -> DiskSpaceStatus {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
    guard let freeSize = attributes[.systemFreeSize] as? NSNumber else {
      throw CocoaError(.fileReadUnknown)
    }
    return status(availableBytes: freeSize.int64Value)
  }
}

public enum AudioRetentionPolicy: String, CaseIterable, Codable, Sendable {
  case immediately
  case sevenDays
  case thirtyDays
  case forever

  public func shouldDeleteAudio(for manifest: SessionManifest, now: Date = Date()) -> Bool {
    guard manifest.status == .completed else { return false }
    switch self {
    case .immediately:
      return true
    case .sevenDays:
      return isOlder(manifest, than: 7, now: now)
    case .thirtyDays:
      return isOlder(manifest, than: 30, now: now)
    case .forever:
      return false
    }
  }

  private func isOlder(_ manifest: SessionManifest, than days: Int, now: Date) -> Bool {
    let referenceDate = manifest.stoppedAt ?? manifest.createdAt
    return now.timeIntervalSince(referenceDate) >= Double(days * 24 * 60 * 60)
  }
}
