// swift-litert-lm — app-side video frame sampling.
//
// Gemma 4 has no native video input, so video understanding is done the way the
// field does it: sample a handful of frames and feed them as images. This
// samples evenly across a clip's duration and returns PNG bytes ready to hand to
// `LiteRTVideoSegment` (FM mode) or `LiteRTChat` (Easy mode).
//
// Memory note: each frame costs visual tokens, so keep `count` small — 4 frames
// at the default per-image budget already approaches Gemma 4 E2B's context. Tune
// `count` (and the model's visual-token budget) to fit.

import Foundation
import AVFoundation
import CoreGraphics

public enum VideoFrameSampler {
  /// Sample `count` frames evenly across the video and return them as PNG bytes.
  ///
  /// - Parameters:
  ///   - url: The video file URL.
  ///   - count: Number of frames to sample (evenly spaced; clamped to ≥ 1).
  ///   - maxDimension: Frames are downscaled so neither side exceeds this.
  public static func sampleFrames(
    from url: URL, count: Int = 4, maxDimension: CGFloat = 512
  ) async throws -> [Data] {
    let n = max(1, count)
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
    // Extract the frame AT each timestamp, not the nearest keyframe — without this
    // (the default is an infinite tolerance) a sparsely-keyframed clip returns the
    // same opening keyframe for every sample.
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    var frames: [Data] = []
    for i in 0..<n {
      // Sample within 10%–90% of the clip — the very start/end are often black,
      // a title card, or a fade, which makes a single representative frame
      // unrelated to the actual content.
      let fraction = n == 1 ? 0.5 : 0.1 + 0.8 * Double(i) / Double(n - 1)
      let seconds = duration.isFinite ? max(0, duration * fraction) : 0
      let time = CMTime(seconds: seconds, preferredTimescale: 600)
      let result = try await generator.image(at: time)
      if let png = pngData(from: result.image) { frames.append(png) }
    }
    return frames
  }
}
