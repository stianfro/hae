import Foundation

public final class PCMFileReader: @unchecked Sendable {
  private let handle: FileHandle

  public init(url: URL) throws {
    handle = try FileHandle(forReadingFrom: url)
  }

  deinit {
    try? handle.close()
  }

  public func seek(toFrame frame: Int64) throws {
    try handle.seek(toOffset: UInt64(max(0, frame)) * 2)
  }

  public func read(frameCount: Int) throws -> [Float] {
    let data = try handle.read(upToCount: max(0, frameCount) * 2) ?? Data()
    return Self.decodePCM16LE(data)
  }

  public static func decodePCM16LE(_ data: Data) -> [Float] {
    let validByteCount = data.count - (data.count % 2)
    guard validByteCount > 0 else { return [] }
    return data.prefix(validByteCount).withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      return stride(from: 0, to: validByteCount, by: 2).map { offset in
        let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        let sample = Int16(bitPattern: bits)
        return sample < 0 ? Float(sample) / 32_768 : Float(sample) / 32_767
      }
    }
  }
}
