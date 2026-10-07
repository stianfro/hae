import Foundation

protocol HostedTranscriptionTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Refusing every redirect prevents audio and credentials being sent to an unexpected destination.
final class HostedTranscriptionRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

private struct HostedURLSessionTransport: HostedTranscriptionTransport {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 300
    configuration.timeoutIntervalForResource = 600
    let session = URLSession(
      configuration: configuration,
      delegate: HostedTranscriptionRedirectDelegate(),
      delegateQueue: nil
    )
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw HostedTranscriptionError.invalidResponse
    }
    // Error bodies can contain sensitive request details and are never needed for user-facing errors.
    guard (200..<300).contains(response.statusCode) else { return (Data(), response) }
    guard response.expectedContentLength <= Int64(HostedTranscriptionService.maximumResponseBytes)
    else {
      throw HostedTranscriptionError.invalidResponse
    }
    var data = Data()
    for try await byte in bytes {
      guard data.count < HostedTranscriptionService.maximumResponseBytes else {
        throw HostedTranscriptionError.invalidResponse
      }
      data.append(byte)
    }
    return (data, response)
  }
}

public struct HostedTranscriptionService: Sendable {
  /// Five minutes of 16 kHz mono PCM16 is 9.6 MB, before the WAV and multipart headers.
  public static let chunkFrames = 300 * 16_000
  static let maximumResponseBytes = 4 * 1_024 * 1_024

  private let transport: any HostedTranscriptionTransport

  public init() {
    transport = HostedURLSessionTransport()
  }

  init(transport: any HostedTranscriptionTransport) {
    self.transport = transport
  }

  public func transcribe(
    pcmURL: URL,
    sessionID: UUID,
    durationFrames: Int64,
    configuration: HostedTranscriptionConfiguration,
    apiKey: String,
    progress: @escaping @Sendable (Double) async -> Void
  ) async throws -> Transcript {
    try Task.checkCancellation()
    let endpoint = try configuration.validatedEndpoint()
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw HostedTranscriptionError.invalidAPIKey
    }
    guard durationFrames >= 0, durationFrames <= Int64.max / 2 else {
      throw HostedTranscriptionError.invalidAudio
    }

    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: pcmURL)
    } catch {
      throw HostedTranscriptionError.unreadableAudio
    }
    defer { try? handle.close() }
    do {
      let byteCount = try handle.seekToEnd()
      guard byteCount.isMultiple(of: 2), byteCount >= UInt64(durationFrames) * 2 else {
        throw HostedTranscriptionError.invalidAudio
      }
      try handle.seek(toOffset: 0)
    } catch let error as HostedTranscriptionError {
      throw error
    } catch {
      throw HostedTranscriptionError.unreadableAudio
    }

    var offsetFrames: Int64 = 0
    var segments: [TranscriptSegment] = []
    while offsetFrames < durationFrames {
      try Task.checkCancellation()
      let frames = Int(min(Int64(Self.chunkFrames), durationFrames - offsetFrames))
      let pcm: Data
      do {
        pcm = try handle.read(upToCount: frames * 2) ?? Data()
      } catch {
        throw HostedTranscriptionError.unreadableAudio
      }
      guard pcm.count == frames * 2 else { throw HostedTranscriptionError.invalidAudio }
      let request = Self.request(
        endpoint: endpoint, configuration: configuration, apiKey: key, pcm: pcm
      )
      let data: Data
      let response: HTTPURLResponse
      do {
        (data, response) = try await transport.send(request)
      } catch {
        if Task.isCancelled || error is CancellationError
          || (error as? URLError)?.code == .cancelled
        {
          throw CancellationError()
        }
        if let error = error as? HostedTranscriptionError { throw error }
        if (error as? URLError)?.code == .timedOut { throw HostedTranscriptionError.timedOut }
        throw HostedTranscriptionError.networkFailure
      }
      try Task.checkCancellation()
      guard (200..<300).contains(response.statusCode) else {
        throw HostedTranscriptionError.httpStatus(response.statusCode)
      }
      segments += try Self.segments(
        from: data, offsetFrames: offsetFrames, frameCount: frames
      )
      offsetFrames += Int64(frames)
      await progress(Double(offsetFrames) / Double(durationFrames))
    }
    try Task.checkCancellation()
    if durationFrames == 0 { await progress(1) }
    return Transcript(sessionID: sessionID, isFinal: true, segments: segments)
  }

  private static func request(
    endpoint: URL,
    configuration: HostedTranscriptionConfiguration,
    apiKey: String,
    pcm: Data
  ) -> URLRequest {
    let boundary = "Hae-\(UUID().uuidString)"
    var body = Data()
    func field(_ name: String, _ value: String) {
      body.append(Data("--\(boundary)\r\n".utf8))
      body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
      body.append(Data("\(value)\r\n".utf8))
    }
    field("model", configuration.model.trimmingCharacters(in: .whitespacesAndNewlines))
    field("response_format", configuration.responseFormat.rawValue)
    let language = configuration.language.trimmingCharacters(in: .whitespacesAndNewlines)
    if !language.isEmpty { field("language", language.lowercased()) }
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(
      Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
    body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
    body.append(wavHeader(pcmByteCount: pcm.count))
    body.append(pcm)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 300
    if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = body
    return request
  }

  private static func wavHeader(pcmByteCount: Int) -> Data {
    var header = Data()
    func append16(_ value: UInt16) {
      header.append(UInt8(truncatingIfNeeded: value))
      header.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    func append32(_ value: UInt32) {
      append16(UInt16(truncatingIfNeeded: value))
      append16(UInt16(truncatingIfNeeded: value >> 16))
    }
    header.append(Data("RIFF".utf8))
    append32(UInt32(pcmByteCount + 36))
    header.append(Data("WAVEfmt ".utf8))
    append32(16)
    append16(1)
    append16(1)
    append32(16_000)
    append32(32_000)
    append16(2)
    append16(16)
    header.append(Data("data".utf8))
    append32(UInt32(pcmByteCount))
    return header
  }

  private struct Response: Decodable {
    struct Segment: Decodable {
      let start: Double
      let end: Double
      let text: String
    }
    let text: String?
    let segments: [Segment]?
  }

  private static func segments(
    from data: Data,
    offsetFrames: Int64,
    frameCount: Int
  ) throws -> [TranscriptSegment] {
    guard data.count <= maximumResponseBytes,
      let response = try? JSONDecoder().decode(Response.self, from: data),
      response.text != nil || response.segments != nil
    else {
      throw HostedTranscriptionError.invalidResponse
    }
    let startMs = Int(offsetFrames / 16)
    let durationMs = frameCount / 16
    guard let segments = response.segments, !segments.isEmpty else {
      let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if text.isEmpty { return [] }
      return [TranscriptSegment(startMs: startMs, endMs: startMs + durationMs, text: text)]
    }
    var output: [TranscriptSegment] = []
    var previousStart: Double = 0
    var previousEnd: Double = 0
    for segment in segments {
      guard segment.start.isFinite, segment.end.isFinite,
        segment.start >= previousStart, segment.end >= max(segment.start, previousEnd)
      else {
        throw HostedTranscriptionError.invalidResponse
      }
      previousStart = segment.start
      previousEnd = segment.end
      let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty { continue }
      let durationSeconds = Double(frameCount) / 16_000
      let localStart = Int((min(segment.start, durationSeconds) * 1_000).rounded())
      let localEnd = Int((min(segment.end, durationSeconds) * 1_000).rounded())
      output.append(
        TranscriptSegment(
          startMs: max(output.last?.endMs ?? startMs, startMs + min(localStart, durationMs)),
          endMs: startMs + min(localEnd, durationMs),
          text: text
        )
      )
    }
    return output
  }
}
