// swift-litert-lm — video through the Foundation Models API.
//
// The beta5 Foundation Models transcript has no custom video segment case.
// Keep the app-sampled video frames (PNG bytes) available as a payload;
// provider-specific integrations can feed them to Gemma 4 as a sequence of images.
// Use `VideoFrameSampler` with a provider-specific integration as needed.
//
//   let frames = try await VideoFrameSampler.sampleFrames(from: videoURL, count: 4)
//   let answer = try await session.respond {
//     LiteRTVideoSegment(frames: frames)
//     "Describe what happens in this video."
//   }

#if canImport(FoundationModels)

import Foundation
import FoundationModels

/// A Foundation Models payload carrying sampled video frames.
@available(iOS 27.0, macOS 27.0, *)
public struct LiteRTVideoSegment: Sendable, Equatable, Identifiable {
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
