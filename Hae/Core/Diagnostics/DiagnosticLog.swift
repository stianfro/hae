import Darwin
import Foundation

/// An opt-in local JSONL log. Files are bounded, and exports contain only decoded metadata.
public actor DiagnosticLog {
  private static let fileName = "diagnostics.jsonl"
  private let directory: URL
  private let maximumEntries: Int
  private let maximumBytes: Int
  private var enabled = false

  public init(
    directory: URL,
    maximumEntries: Int = 1_000,
    maximumBytes: Int = 1_048_576
  ) {
    self.directory = directory
    self.maximumEntries = max(0, maximumEntries)
    self.maximumBytes = max(0, maximumBytes)
  }

  public func setEnabled(_ enabled: Bool) throws {
    guard enabled != self.enabled else { return }
    if enabled {
      try append(DiagnosticEvent(kind: .debugEnabled))
    }
    self.enabled = enabled
  }

  public func record(_ event: DiagnosticEvent) throws {
    guard enabled else { return }
    try append(event)
  }

  public func exportData() throws -> Data {
    guard let descriptor = try openDirectory() else { return Data() }
    defer { close(descriptor) }
    return try boundedData(for: readEvents(in: descriptor))
  }

  public func clear() throws {
    guard let descriptor = try openDirectory() else { return }
    defer { close(descriptor) }
    // Unlink only the owned filename, never the directory or a symlink's destination.
    guard unlinkat(descriptor, Self.fileName, 0) == 0 || errno == ENOENT else {
      throw StorageError.unavailable
    }
  }

  private func append(_ event: DiagnosticEvent) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    guard let descriptor = try openDirectory() else {
      throw StorageError.unavailable
    }
    defer { close(descriptor) }
    guard fchmod(descriptor, 0o700) == 0 else { throw StorageError.unavailable }
    var events = try readEvents(in: descriptor)
    events.append(event)
    try writeAtomically(try boundedData(for: events), in: descriptor)
  }

  private func openDirectory() throws -> Int32? {
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw StorageError.unavailable
    }
    var information = stat()
    guard fstat(descriptor, &information) == 0, information.st_uid == getuid() else {
      close(descriptor)
      throw StorageError.unavailable
    }
    return descriptor
  }

  private func readEvents(in directoryDescriptor: Int32) throws -> [DiagnosticEvent] {
    let descriptor = openat(
      directoryDescriptor, Self.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      if errno == ENOENT { return [] }
      throw StorageError.unavailable
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var information = stat()
    guard fstat(descriptor, &information) == 0,
      information.st_mode & S_IFMT == S_IFREG,
      information.st_uid == getuid(), information.st_nlink == 1
    else {
      throw StorageError.unavailable
    }
    // Reject oversized input without loading it. A later record replaces it with safe metadata.
    guard information.st_size <= maximumBytes else { return [] }
    var data = Data()
    while data.count < maximumBytes {
      let part = try handle.read(upToCount: min(65_536, maximumBytes - data.count)) ?? Data()
      guard !part.isEmpty else { break }
      data.append(part)
    }
    // Also bound a file that grew after fstat.
    guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { return [] }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return data.split(separator: 0x0A).compactMap { line in
      try? decoder.decode(DiagnosticEvent.self, from: Data(line))
    }
  }

  private func boundedData(for events: [DiagnosticEvent]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let lines = try events.suffix(maximumEntries).map { event in
      var line = try encoder.encode(event)
      line.append(0x0A)
      return line
    }
    var byteCount = lines.reduce(0) { $0 + $1.count }
    var start = 0
    while byteCount > maximumBytes, start < lines.count {
      byteCount -= lines[start].count
      start += 1
    }
    return lines.dropFirst(start).reduce(into: Data()) { $0.append($1) }
  }

  private func writeAtomically(_ data: Data, in directoryDescriptor: Int32) throws {
    let temporaryName = ".diagnostics.\(UUID().uuidString).tmp"
    let descriptor = openat(
      directoryDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
    )
    guard descriptor >= 0 else { throw StorageError.unavailable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer {
      try? handle.close()
      unlinkat(directoryDescriptor, temporaryName, 0)
    }
    guard fchmod(descriptor, 0o600) == 0 else { throw StorageError.unavailable }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, Self.fileName) == 0
    else {
      throw StorageError.unavailable
    }
  }

  private enum StorageError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
      "The private diagnostic log is unavailable."
    }
  }
}
