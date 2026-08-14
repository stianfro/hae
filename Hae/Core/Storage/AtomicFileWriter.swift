import Foundation

public enum AtomicFileWriter {
  public static func write(_ data: Data, to destination: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    manager.createFile(atPath: temporary.path, contents: nil)

    do {
      let handle = try FileHandle(forWritingTo: temporary)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()

      if manager.fileExists(atPath: destination.path) {
        _ = try manager.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try manager.moveItem(at: temporary, to: destination)
      }
    } catch {
      try? manager.removeItem(at: temporary)
      throw error
    }
  }
}
