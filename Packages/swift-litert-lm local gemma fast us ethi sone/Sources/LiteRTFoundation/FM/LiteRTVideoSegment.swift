// swift-litert-lm — video through the Foundation Models API.
//
// Like audio, video has no built-in FM transcript segment. `LiteRTVideoSegment`
// carries app-sampled video frames (PNG bytes) through the custom-segment hook;
// the executor feeds them to Gemma 4 as a sequence of images. Pair it with
// `VideoFrameSampler` — video understanding through the Foundation Models API,
// which Apple's system model does not offer.
//
//   let frames = try await VideoFrameSampler.sampleFrames(from: videoURL, count: 4)
//   let answer = try await session.respond {
//     LiteRTVideoSegment(frames: frames)
//     "Describe what happens in this video."
//   }

#if canImport(FoundationModels)

import Foundation
import FoundationModels

/// A Foundation Models prompt segment carrying sampled video frames.
@available(iOS 27.0, macOS 27.0, *)
public struct LiteRTVideoSegment: Transcript.CustomSegment {
  /// Sampled frames as image bytes (e.g. PNG), in temporal order.
  public struct Content: Codable, Equatable, Sendable {
    public var frames: [Data]
    public init(frames: [Data]) { self.frames = frames }
  }

  public let id: String
  public let content: Content

  public init(frames: [Data], id: String = UUID().uuidString) {
    self.id = id
    self.content = Content(frames: frames)
  }
}

#endif
