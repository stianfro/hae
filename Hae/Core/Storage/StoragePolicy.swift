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
