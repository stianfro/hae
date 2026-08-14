import Foundation

#if canImport(whisper)
  import whisper

  private final class WhisperContext: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
      self.pointer = pointer
    }

    deinit {
      whisper_free(pointer)
    }
  }
#endif

public enum WhisperEngineError: Error, LocalizedError, Sendable {
  case runtimeUnavailable
  case modelLoadFailed
  case modelNotLoaded
  case inferenceFailed(Int32)

  public var errorDescription: String? {
    switch self {
    case .runtimeUnavailable:
      "The embedded whisper.cpp framework has not been built."
    case .modelLoadFailed:
      "whisper.cpp could not load the verified model."
    case .modelNotLoaded:
      "The transcription model is not loaded."
    case .inferenceFailed(let code):
      "whisper.cpp inference failed with code \(code)."
    }
  }
}

public actor WhisperEngine {
  #if canImport(whisper)
    private var context: WhisperContext?
  #endif
  private var vadModelURL: URL?

  public init() {}

  public func loadModel(at modelURL: URL, vadModelURL: URL) throws {
    #if canImport(whisper)
      context = nil
      self.vadModelURL = nil
      var parameters = whisper_context_default_params()
      parameters.use_gpu = true
      parameters.flash_attn = true
      guard let loaded = whisper_init_from_file_with_params(modelURL.path, parameters) else {
        throw WhisperEngineError.modelLoadFailed
      }
      context = WhisperContext(loaded)
      self.vadModelURL = vadModelURL
    #else
      throw WhisperEngineError.runtimeUnavailable
    #endif
  }

  public func unload() {
    #if canImport(whisper)
      context = nil
    #endif
    vadModelURL = nil
  }

  public func transcribe(
    samples: [Float],
    parameters: WhisperParameters = .final
  ) throws -> [TranscriptSegment] {
    guard !samples.isEmpty else { return [] }
    #if canImport(whisper)
      guard let context, let vadModelURL else { throw WhisperEngineError.modelNotLoaded }
      var whisperParameters = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
      whisperParameters.n_threads = Int32(
        max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
      whisperParameters.translate = false
      whisperParameters.no_context = true
      whisperParameters.no_timestamps = false
      whisperParameters.print_special = false
      whisperParameters.print_progress = false
      whisperParameters.print_realtime = false
      whisperParameters.print_timestamps = false
      whisperParameters.temperature = 0
      whisperParameters.beam_search.beam_size = parameters.beamSize
      whisperParameters.vad = true
      whisperParameters.vad_params.threshold = parameters.vadThreshold
      whisperParameters.vad_params.min_speech_duration_ms = parameters.minimumSpeechMilliseconds
      whisperParameters.vad_params.min_silence_duration_ms = parameters.minimumSilenceMilliseconds
      whisperParameters.vad_params.speech_pad_ms = parameters.speechPaddingMilliseconds
      whisperParameters.vad_params.max_speech_duration_s = parameters.maximumSpeechSeconds
      whisperParameters.vad_params.samples_overlap = parameters.sampleOverlapSeconds

      let result: Int32 = parameters.language.withCString { language in
        vadModelURL.path.withCString { vadPath in
          whisperParameters.language = language
          whisperParameters.vad_model_path = vadPath
          return samples.withUnsafeBufferPointer { pointer in
            whisper_full(
              context.pointer, whisperParameters, pointer.baseAddress, Int32(pointer.count))
          }
        }
      }
      guard result == 0 else { throw WhisperEngineError.inferenceFailed(result) }

      return (0..<whisper_full_n_segments(context.pointer)).compactMap { index in
        let text = String(cString: whisper_full_get_segment_text(context.pointer, index))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return TranscriptSegment(
          startMs: Int(whisper_full_get_segment_t0(context.pointer, index)) * 10,
          endMs: Int(whisper_full_get_segment_t1(context.pointer, index)) * 10,
          text: text
        )
      }
    #else
      throw WhisperEngineError.runtimeUnavailable
    #endif
  }
}
