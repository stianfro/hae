import Accelerate
import Foundation

public enum AudioLevelMeter {
  public static func normalizedLevel(samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var rms: Float = 0
    vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
    guard rms > 0 else { return 0 }
    let decibels = 20 * log10(rms)
    return min(1, max(0, (decibels + 60) / 60))
  }
}
