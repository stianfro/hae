import Foundation
import Testing

@testable import HaeCore

@Suite
struct HostedTranscriptionTests {
  private let configuration = HostedTranscriptionConfiguration(
    baseURL: "https://speech.example.com/v1", model: "speech-model"
  )

  @Test
  func validatesAndNormalizesEndpoint() throws {
    var value = configuration
    value.baseURL = " HTTPS://SPEECH.EXAMPLE.COM/v1/// "
    #expect(
      try value.validatedEndpoint().absoluteString
        == "https://speech.example.com/v1/audio/transcriptions"
    )
    value.baseURL = "https://SPEECH.EXAMPLE.COM:443/tenant%2Fslug/v1/"
    #expect(
      try value.validatedEndpoint().absoluteString
        == "https://speech.example.com/tenant%2Fslug/v1/audio/transcriptions"
    )
    let encoded = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(HostedTranscriptionConfiguration.self, from: encoded) == value)
    #expect(TranscriptionProvider.allCases == [.local, .hosted])
  }

  @Test(arguments: [
    "", "not a url", "http://speech.example.com/v1", "file:///tmp/model",
    "https://user:password@speech.example.com/v1", "https://speech.example.com/v1?key=secret",
    "https://speech.example.com/v1#section", "https:///v1", "https://speech.example.com:0/v1",
    "https://speech.example.com:70000/v1", "https://speech.example.com/my path",
  ])
  func rejectsUnsafeEndpoint(address: String) {
    var value = configuration
    value.baseURL = address
    #expect(throws: HostedTranscriptionError.invalidBaseURL) { try value.validatedEndpoint() }
  }

  @Test
  func validatesModelAndLanguage() {
    var value = configuration
    value.model = " \n "
    #expect(throws: HostedTranscriptionError.invalidModel) { try value.validatedEndpoint() }
    value.model = "model\nname"
    #expect(throws: HostedTranscriptionError.invalidModel) { try value.validatedEndpoint() }
    value.model = "speech-model"
    value.language = "Norwegian"
    #expect(throws: HostedTranscriptionError.invalidLanguage) { try value.validatedEndpoint() }
    value.language = "nb"
    #expect(throws: Never.self) { try value.validatedEndpoint() }
  }

  @Test
  func uploadsMultipartWAVAndReturnsJSONTranscript() async throws {
    let pcm = Data([0x00, 0x80, 0xff, 0x7f])
    let file = try temporaryPCM(pcm)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [.json("{\"text\":\"  Hei!  \"}")])
    let service = HostedTranscriptionService(transport: transport)
    var config = configuration
    config.language = "NB"
    let sessionID = UUID()
    let progress = HostedProgressRecorder()
    let result = try await service.transcribe(
      pcmURL: file, sessionID: sessionID, durationFrames: 2,
      configuration: config, apiKey: "test-key",
      progress: { await progress.record($0) }
    )
    #expect(result.sessionID == sessionID)
    #expect(result.isFinal)
    #expect(result.segments.map(\.text) == ["Hei!"])
    #expect(await progress.values == [1])

    let request = try #require(await transport.requests.first)
    #expect(request.url?.absoluteString == "https://speech.example.com/v1/audio/transcriptions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    let body = try #require(request.httpBody)
    let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
    let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
    #expect(body.starts(with: Data("--\(boundary)\r\n".utf8)))
    #expect(
      body.suffix(Data("\r\n--\(boundary)--\r\n".utf8).count)
        == Data("\r\n--\(boundary)--\r\n".utf8))
    #expect(body.range(of: Data("name=\"model\"\r\n\r\nspeech-model\r\n".utf8)) != nil)
    #expect(body.range(of: Data("name=\"response_format\"\r\n\r\njson\r\n".utf8)) != nil)
    #expect(body.range(of: Data("name=\"language\"\r\n\r\nnb\r\n".utf8)) != nil)
    #expect(
      body.range(of: Data("filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n".utf8)) != nil)
    let waveStart = try #require(body.range(of: Data("RIFF".utf8))).lowerBound
    let wav = body.subdata(in: waveStart..<(waveStart + 44 + pcm.count))
    #expect(wav.prefix(4) == Data("RIFF".utf8))
    #expect(readUInt32(wav, at: 4) == 40)
    #expect(wav.subdata(in: 8..<16) == Data("WAVEfmt ".utf8))
    #expect(readUInt32(wav, at: 16) == 16)
    #expect(wav.subdata(in: 20..<24) == Data([1, 0, 1, 0]))
    #expect(readUInt32(wav, at: 24) == 16_000)
    #expect(readUInt32(wav, at: 28) == 32_000)
    #expect(wav.subdata(in: 32..<36) == Data([2, 0, 16, 0]))
    #expect(wav.subdata(in: 36..<40) == Data("data".utf8))
    #expect(readUInt32(wav, at: 40) == 4)
    #expect(wav.suffix(4) == pcm)
    #expect(body.range(of: Data(file.lastPathComponent.utf8)) == nil)
    #expect(body.range(of: Data("test-key".utf8)) == nil)
  }

  @Test
  func chunksMeetingsAndOffsetsVerboseTimestamps() async throws {
    let frames = HostedTranscriptionService.chunkFrames + 16_000
    let file = try temporaryPCM(Data(repeating: 0, count: frames * 2))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [
      .json("{\"text\":\"First\",\"segments\":[{\"start\":1.25,\"end\":2.5,\"text\":\"First\"}]}"),
      .json("{\"text\":\"Second\",\"segments\":[{\"start\":0.2,\"end\":0.8,\"text\":\"Second\"}]}"),
    ])
    var config = configuration
    config.responseFormat = .verboseJSON
    let progress = HostedProgressRecorder()
    let diagnostics = HostedDiagnosticRecorder()
    let result = try await HostedTranscriptionService(transport: transport).transcribe(
      pcmURL: file, sessionID: UUID(), durationFrames: Int64(frames),
      configuration: config, apiKey: "test-key",
      diagnostic: { await diagnostics.record($0) }, progress: { await progress.record($0) }
    )
    #expect(result.segments.map(\.startMs) == [1_250, 300_200])
    #expect(result.segments.map(\.endMs) == [2_500, 300_800])
    let requests = await transport.requests
    #expect(requests.count == 2)
    let bodies = try requests.map { try #require($0.httpBody) }
    for (index, body) in bodies.enumerated() {
      #expect(body.count < HostedTranscriptionService.chunkFrames * 2 + 1_024)
      #expect(body.range(of: Data("name=\"language\"".utf8)) == nil)
      #expect(body.range(of: Data("verbose_json".utf8)) != nil)
      let waveStart = try #require(body.range(of: Data("RIFF".utf8))).lowerBound
      let expectedBytes = index == 0 ? HostedTranscriptionService.chunkFrames * 2 : 32_000
      #expect(readUInt32(body, at: waveStart + 40) == UInt32(expectedBytes))
    }
    #expect(await progress.values == [300.0 / 301.0, 1])
    let events = await diagnostics.events
    #expect(
      events.map(\.kind) == [
        .hostedRequestStarted, .hostedResponseReceived, .hostedRequestStarted,
        .hostedResponseReceived,
      ])
    #expect(events.map(\.chunk) == [1, 1, 2, 2])
    #expect(events.allSatisfy { $0.chunkCount == 2 })
    #expect(Set(events.compactMap(\.operationID)).count == 1)
    #expect(events.map(\.audioBytes) == [9_600_000, 9_600_000, 32_000, 32_000])
    #expect(events.map(\.audioDurationMS) == [300_000, 300_000, 1_000, 1_000])
    #expect(events.allSatisfy { $0.hasAPIKey == true && $0.responseFormat == .verboseJSON })
    #expect(events.allSatisfy { $0.elapsedMS.map { $0 >= 0 } == true })
    #expect(events.map(\.statusCode) == [nil, 200, nil, 200])
    #expect(events.allSatisfy { $0.failure == nil })
  }

  @Test
  func jsonResponseUsesChunkBoundsAndAcceptsSilence() async throws {
    let frames = HostedTranscriptionService.chunkFrames + 16_000
    let file = try temporaryPCM(Data(repeating: 0, count: frames * 2))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [
      .json("{\"text\":\"\"}"), .json("{\"text\":\"Last second\"}"),
    ])
    let result = try await HostedTranscriptionService(transport: transport).transcribe(
      pcmURL: file, sessionID: UUID(), durationFrames: Int64(frames),
      configuration: configuration, apiKey: "test-key", progress: { _ in }
    )
    #expect(result.segments.count == 1)
    #expect(result.segments.first?.startMs == 300_000)
    #expect(result.segments.first?.endMs == 301_000)
  }

  @Test
  func emptyRecordingMakesNoRequests() async throws {
    let file = try temporaryPCM(Data())
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [])
    let progress = HostedProgressRecorder()
    let result = try await HostedTranscriptionService(transport: transport).transcribe(
      pcmURL: file, sessionID: UUID(), durationFrames: 0,
      configuration: configuration, apiKey: "test-key", progress: { await progress.record($0) }
    )
    #expect(result.segments.isEmpty)
    #expect(await transport.requests.isEmpty)
    #expect(await progress.values == [1])
  }

  @Test(arguments: [401, 403, 404, 400, 413, 415, 422, 429, 500, 302])
  func reportsSafeHTTPErrorWithoutRetryOrFallback(status: Int) async throws {
    let file = try temporaryPCM(Data([0, 0]))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [
      .http(status, "server-payload-secret")
    ])
    await #expect(throws: HostedTranscriptionError.httpStatus(status)) {
      try await HostedTranscriptionService(transport: transport).transcribe(
        pcmURL: file, sessionID: UUID(), durationFrames: 1,
        configuration: configuration, apiKey: "test-key", progress: { _ in }
      )
    }
    #expect(await transport.requests.count == 1)
    #expect(!HostedTranscriptionError.httpStatus(status).localizedDescription.contains("secret"))
    #expect(
      HostedTranscriptionError.httpStatus(status).localizedDescription.contains("HTTP \(status)"))
  }

  @Test(arguments: [
    "{}", "[]", "not JSON", "{\"segments\":[{\"start\":-1,\"end\":1,\"text\":\"x\"}]}",
  ])
  func rejectsUnsupportedResponses(json: String) async throws {
    let file = try temporaryPCM(Data([0, 0]))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [.json(json)])
    await #expect(throws: HostedTranscriptionError.invalidResponse) {
      try await HostedTranscriptionService(transport: transport).transcribe(
        pcmURL: file, sessionID: UUID(), durationFrames: 1,
        configuration: configuration, apiKey: "test-key", progress: { _ in }
      )
    }
  }

  @Test
  func rejectsRegressingTimestamps() async throws {
    let file = try temporaryPCM(Data(repeating: 0, count: 32_000))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [
      .json(
        "{\"segments\":[{\"start\":0.5,\"end\":0.8,\"text\":\"First\"},{\"start\":0.1,\"end\":0.4,\"text\":\"Second\"}]}"
      )
    ])
    await #expect(throws: HostedTranscriptionError.invalidResponse) {
      try await HostedTranscriptionService(transport: transport).transcribe(
        pcmURL: file, sessionID: UUID(), durationFrames: 16_000,
        configuration: configuration, apiKey: "test-key", progress: { _ in }
      )
    }
  }

  @Test
  func boundsOverlappingSegmentsToMonotonicChunkTimeline() async throws {
    let file = try temporaryPCM(Data(repeating: 0, count: 32_000))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [
      .json(
        "{\"segments\":[{\"start\":0,\"end\":0.8,\"text\":\"First\"},{\"start\":0.7,\"end\":1.1,\"text\":\"Second\"}]}"
      )
    ])
    let result = try await HostedTranscriptionService(transport: transport).transcribe(
      pcmURL: file, sessionID: UUID(), durationFrames: 16_000,
      configuration: configuration, apiKey: "test-key", progress: { _ in }
    )
    #expect(result.segments.map(\.startMs) == [0, 800])
    #expect(result.segments.map(\.endMs) == [800, 1_000])
  }

  @Test
  func validatesCredentialsBeforeSendingAudio() async throws {
    let file = try temporaryPCM(Data([0, 0]))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [])
    for (key, error) in [
      ("abc\r\nInjected: header", HostedTranscriptionError.invalidAPIKey)
    ] {
      await #expect(throws: error) {
        try await HostedTranscriptionService(transport: transport).transcribe(
          pcmURL: file, sessionID: UUID(), durationFrames: 1,
          configuration: configuration, apiKey: key, progress: { _ in }
        )
      }
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test
  func omitsAuthorizationForServersWithoutAuthentication() async throws {
    let file = try temporaryPCM(Data([0, 0]))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [.json("{\"text\":\"Hello\"}")])
    _ = try await HostedTranscriptionService(transport: transport).transcribe(
      pcmURL: file, sessionID: UUID(), durationFrames: 1,
      configuration: configuration, apiKey: "", progress: { _ in }
    )
    let request = try #require(await transport.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test
  func rejectsTruncatedPCMWithoutUploading() async throws {
    for pcm in [Data([0]), Data([0, 0])] {
      let file = try temporaryPCM(pcm)
      defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
      let transport = HostedStubTransport(replies: [])
      await #expect(throws: HostedTranscriptionError.invalidAudio) {
        try await HostedTranscriptionService(transport: transport).transcribe(
          pcmURL: file, sessionID: UUID(), durationFrames: 2,
          configuration: configuration, apiKey: "test-key", progress: { _ in }
        )
      }
      #expect(await transport.requests.isEmpty)
    }
  }

  @Test
  func mapsNetworkErrorsWithoutLeakingURLs() async throws {
    let file = try temporaryPCM(Data([0, 0]))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    for (code, error) in [
      (URLError.Code.timedOut, HostedTranscriptionError.timedOut),
      (
        URLError.Code.notConnectedToInternet,
        HostedTranscriptionError.networkFailureCode(URLError.Code.notConnectedToInternet.rawValue)
      ),
    ] {
      let transport = HostedStubTransport(replies: [.network(code)])
      await #expect(throws: error) {
        try await HostedTranscriptionService(transport: transport).transcribe(
          pcmURL: file, sessionID: UUID(), durationFrames: 1,
          configuration: configuration, apiKey: "test-key", progress: { _ in }
        )
      }
    }
  }

  @Test
  func cancellationStopsActiveUpload() async throws {
    let file = try temporaryPCM(Data([0, 0]))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [], suspends: true)
    let diagnostics = HostedDiagnosticRecorder()
    let task = Task {
      try await HostedTranscriptionService(transport: transport).transcribe(
        pcmURL: file, sessionID: UUID(), durationFrames: 1,
        configuration: configuration, apiKey: "test-key",
        diagnostic: { await diagnostics.record($0) }, progress: { _ in }
      )
    }
    await transport.waitForRequest()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await transport.requests.count == 1)
    let events = await diagnostics.events
    #expect(events.map(\.kind) == [.hostedRequestStarted, .hostedRequestFailed])
    #expect(events.last?.failure == .cancelled)
    #expect(events.last?.statusCode == nil)
  }

  @Test
  func rejectsRedirectsRatherThanForwardingCredentials() async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let destination = try #require(URL(string: "https://different.example.com/upload"))
    let request = URLRequest(url: destination)
    let response = try #require(
      HTTPURLResponse(url: destination, statusCode: 307, httpVersion: nil, headerFields: nil)
    )
    let redirected: URLRequest? = await withCheckedContinuation { continuation in
      HostedTranscriptionRedirectDelegate().urlSession(
        session, task: session.dataTask(with: request),
        willPerformHTTPRedirection: response, newRequest: request,
        completionHandler: { continuation.resume(returning: $0) }
      )
    }
    #expect(redirected == nil)
  }

  @Test(arguments: [false, true])
  func recordsHTTPFailureAndAuthenticationPresenceWithoutSecrets(hasKey: Bool) async throws {
    let file = try temporaryPCM(Data([0, 0]))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [.http(401, "server-payload-private-transcript")])
    let diagnostics = HostedDiagnosticRecorder()
    var config = configuration
    config.baseURL = "https://private-server.example.com/private-tenant/v1"
    config.model = "private-model-name"
    let sessionID = UUID()
    await #expect(throws: HostedTranscriptionError.httpStatus(401)) {
      try await HostedTranscriptionService(transport: transport).transcribe(
        pcmURL: file, sessionID: sessionID, durationFrames: 1,
        configuration: config, apiKey: hasKey ? "secret-api-key" : "",
        diagnostic: { await diagnostics.record($0) }, progress: { _ in }
      )
    }
    let events = await diagnostics.events
    #expect(
      events.map(\.kind) == [
        .hostedRequestStarted, .hostedResponseReceived, .hostedRequestFailed,
      ])
    #expect(events.allSatisfy { $0.hasAPIKey == hasKey })
    #expect(events.last?.statusCode == 401)
    #expect(events.last?.failure == .http)
    #expect(events.last?.chunk == 1 && events.last?.chunkCount == 1)
    let encoded = try JSONEncoder().encode(events)
    let json = String(decoding: encoded, as: UTF8.self)
    for secret in [
      config.baseURL, "private-server", "private-tenant", config.model, "secret-api-key",
      "server-payload-private-transcript", file.path, file.lastPathComponent, sessionID.uuidString,
    ] {
      #expect(!json.contains(secret))
    }
    let decoded = try JSONDecoder().decode([DiagnosticEvent].self, from: encoded)
    #expect(decoded.map(\.kind) == events.map(\.kind))
  }

  @Test(arguments: [URLError.Code.cannotFindHost, .notConnectedToInternet, .secureConnectionFailed])
  func preservesNumericNetworkFailuresWithoutUnderlyingDescription(code: URLError.Code) async throws
  {
    let file = try temporaryPCM(Data([0, 0]))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [.network(code)])
    let diagnostics = HostedDiagnosticRecorder()
    let expected = HostedTranscriptionError.networkFailureCode(code.rawValue)
    await #expect(throws: expected) {
      try await HostedTranscriptionService(transport: transport).transcribe(
        pcmURL: file, sessionID: UUID(), durationFrames: 1,
        configuration: configuration, apiKey: "test-key",
        diagnostic: { await diagnostics.record($0) }, progress: { _ in }
      )
    }
    let events = await diagnostics.events
    #expect(events.map(\.kind) == [.hostedRequestStarted, .hostedRequestFailed])
    #expect(events.last?.networkCode == code.rawValue)
    #expect(events.last?.failure == .network)
    #expect(events.last?.statusCode == nil)
    #expect(expected.localizedDescription.contains("network error \(code.rawValue)"))
    #expect(!expected.localizedDescription.contains("private-network-error"))
    let serialized = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
    #expect(!serialized.contains("private-network-error"))
  }

  @Test
  func recordsTimeoutCategoryAndNumericCode() async throws {
    let file = try temporaryPCM(Data([0, 0]))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [.network(.timedOut)])
    let diagnostics = HostedDiagnosticRecorder()
    await #expect(throws: HostedTranscriptionError.timedOut) {
      try await HostedTranscriptionService(transport: transport).transcribe(
        pcmURL: file, sessionID: UUID(), durationFrames: 1,
        configuration: configuration, apiKey: "test-key",
        diagnostic: { await diagnostics.record($0) }, progress: { _ in }
      )
    }
    let events = await diagnostics.events
    #expect(events.map(\.kind) == [.hostedRequestStarted, .hostedRequestFailed])
    #expect(events.last?.failure == .timeout)
    #expect(events.last?.networkCode == URLError.Code.timedOut.rawValue)
  }

  @Test
  func recordsTransportCancellationCode() async throws {
    let file = try temporaryPCM(Data([0, 0]))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = HostedStubTransport(replies: [.network(.cancelled)])
    let diagnostics = HostedDiagnosticRecorder()
    await #expect(throws: CancellationError.self) {
      try await HostedTranscriptionService(transport: transport).transcribe(
        pcmURL: file, sessionID: UUID(), durationFrames: 1,
        configuration: configuration, apiKey: "test-key",
        diagnostic: { await diagnostics.record($0) }, progress: { _ in }
      )
    }
    let events = await diagnostics.events
    #expect(events.map(\.kind) == [.hostedRequestStarted, .hostedRequestFailed])
    #expect(events.last?.failure == .cancelled)
    #expect(events.last?.networkCode == URLError.Code.cancelled.rawValue)
  }

  @Test
  func recordsResponseFailureWithoutResponseContent() async throws {
    let file = try temporaryPCM(Data([0, 0]))
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let body = "private-invalid-response"
    let transport = HostedStubTransport(replies: [.http(200, body)])
    let diagnostics = HostedDiagnosticRecorder()
    await #expect(throws: HostedTranscriptionError.invalidResponse) {
      try await HostedTranscriptionService(transport: transport).transcribe(
        pcmURL: file, sessionID: UUID(), durationFrames: 1,
        configuration: configuration, apiKey: "test-key",
        diagnostic: { await diagnostics.record($0) }, progress: { _ in }
      )
    }
    let events = await diagnostics.events
    #expect(
      events.map(\.kind) == [
        .hostedRequestStarted, .hostedResponseReceived, .hostedRequestFailed,
      ])
    #expect(events.last?.failure == .invalidResponse)
    #expect(events.last?.statusCode == 200)
    #expect(events.last?.responseBytes == body.utf8.count)
    let serialized = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
    #expect(!serialized.contains(body))
  }

  @Test
  func unknownNetworkCodeUsesSafeGenericDescription() {
    let error = HostedTranscriptionError.networkFailureCode(-999_999)
    #expect(error.localizedDescription.contains("network error -999999"))
    #expect(error.localizedDescription.contains("Check the endpoint and network connection"))
  }

  private func temporaryPCM(_ data: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("private-recording-name.pcm16le")
    try data.write(to: file)
    return file
  }

  private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << ($1 * 8)) }
  }
}

private actor HostedProgressRecorder {
  var values: [Double] = []

  func record(_ value: Double) {
    values.append(value)
  }
}

private actor HostedDiagnosticRecorder {
  var events: [DiagnosticEvent] = []

  func record(_ event: DiagnosticEvent) {
    events.append(event)
  }
}

private actor HostedStubTransport: HostedTranscriptionTransport {
  enum Reply: Sendable {
    case http(Int, String)
    case network(URLError.Code)

    static func json(_ value: String) -> Self { .http(200, value) }
  }

  private var replies: [Reply]
  private let suspends: Bool
  private var waiter: CheckedContinuation<Void, Never>?
  var requests: [URLRequest] = []

  init(replies: [Reply], suspends: Bool = false) {
    self.replies = replies
    self.suspends = suspends
  }

  func waitForRequest() async {
    if !requests.isEmpty { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    waiter?.resume()
    waiter = nil
    if suspends { try await Task.sleep(for: .seconds(30)) }
    guard !replies.isEmpty else { throw HostedTranscriptionError.invalidResponse }
    switch replies.removeFirst() {
    case .http(let status, let body):
      let url = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(
          url: url, statusCode: status, httpVersion: nil, headerFields: nil)
      )
      return (Data(body.utf8), response)
    case .network(let code):
      throw URLError(code, userInfo: [NSLocalizedDescriptionKey: "private-network-error"])
    }
  }
}
