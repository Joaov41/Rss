// swift-litert-lm — audio through the Foundation Models API.
//
// Apple's Foundation Models transcript has built-in text and *image* segments,
// but no audio. The custom-segment hook (`Transcript.CustomSegment`) lets a
// backend carry arbitrary modalities through the FM API. `LiteRTAudioSegment`
// uses it to feed audio into Gemma 4's audio tower — audio understanding through
// the Foundation Models API, which Apple's own system model does not offer.
//
//   let model   = try await LiteRTLanguageModel(.gemma4_E2B)
//   let session = LanguageModelSession(model: model)
//   let answer  = try await session.respond {
//     LiteRTAudioSegment(data: wavBytes)
//     "Transcribe the spoken words."
//   }

#if canImport(FoundationModels)

import Foundation
import FoundationModels

/// A Foundation Models prompt segment carrying audio for a LiteRT backend.
///
/// `Transcript.CustomSegment` supplies `promptRepresentation`, `description`, and
/// equality for free; we only provide `id` + `content`. Include it in a prompt
/// via the `@PromptBuilder` overloads of `respond`/`streamResponse`.
@available(iOS 27.0, macOS 27.0, *)
public struct LiteRTAudioSegment: Transcript.CustomSegment {
  /// The segment payload. Must be `Codable`/`Equatable`/`Sendable` per the
  /// protocol; raw audio bytes (e.g. a WAV file's contents) satisfy that.
  public struct Content: Codable, Equatable, Sendable {
    public var data: Data
    public init(data: Data) { self.data = data }
  }

  public let id: String
  public let content: Content

  /// - Parameters:
  ///   - data: Raw audio bytes (WAV / supported container).
  ///   - id: Stable identifier for the segment.
  public init(data: Data, id: String = UUID().uuidString) {
    self.id = id
    self.content = Content(data: data)
  }

  /// Convenience for audio already on disk.
  public init(fileURL: URL, id: String = UUID().uuidString) throws {
    self.id = id
    self.content = Content(data: try Data(contentsOf: fileURL))
  }
}

#endif
