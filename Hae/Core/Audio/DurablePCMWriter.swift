import Foundation

public enum DurablePCMWriterError: Error, LocalizedError, Sendable {
  case alreadyFinished
  case writeFailed(String)

  public var errorDescription: String? {
    switch self {
    case .alreadyFinished:
      "The PCM writer is already closed."
    case .writeFailed(let message):
      "Could not write durable audio: \(message)"
    }
  }
}

public final class DurablePCMWriter: @unchecked Sendable {
  private let queue = DispatchQueue(label: "no.froystein.hae.storage")
  private let handle: FileHandle
  private var storedError: Error?
  private var isFinished = false
  private var writtenFrames: Int64 = 0

  public init(url: URL) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try FileHandle(forWritingTo: url)
  }

  public func append(_ samples: [Float]) {
    guard !samples.isEmpty else { return }
    queue.async { [self] in
      guard !isFinished, storedError == nil else { return }
      var pcm = samples.map { sample -> Int16 in
        let clamped = min(1, max(-1, sample))
        let scaled = clamped < 0 ? clamped * 32_768 : clamped * 32_767
        return Int16(scaled.rounded()).littleEndian
      }
      do {
        try pcm.withUnsafeBytes { bytes in
          try handle.write(contentsOf: Data(bytes))
        }
        writtenFrames += Int64(pcm.count)
      } catch {
        storedError = error
      }
      pcm.removeAll(keepingCapacity: false)
    }
  }

  public func finish() async throws -> Int64 {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        guard !isFinished else {
          continuation.resume(throwing: DurablePCMWriterError.alreadyFinished)
          return
        }
        do {
          if let storedError { throw storedError }
          try handle.synchronize()
          try handle.close()
          isFinished = true
          continuation.resume(returning: writtenFrames)
        } catch {
          continuation.resume(
            throwing: DurablePCMWriterError.writeFailed(error.localizedDescription)
          )
        }
      }
    }
  }
}
