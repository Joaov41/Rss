// swift-litert-lm — audio through the Foundation Models API.
//
// The Xcode 27 beta 5 Foundation Models transcript has text and image
// segments, but no custom audio segment case. Keep this payload type available
// for callers that store audio alongside prompts.
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

/// A Foundation Models payload carrying audio for a LiteRT backend.
/// The payload remains `Codable`, `Equatable`, and `Sendable` for storage and
/// can be reintroduced into a provider-specific prompt representation later.
@available(iOS 27.0, macOS 27.0, *)
public struct LiteRTAudioSegment: Sendable, Equatable, Identifiable {
  /// Raw audio bytes (e.g. a WAV file's contents) satisfy the payload's
  /// `Codable`/`Equatable`/`Sendable` requirements.
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
