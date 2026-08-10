// swift-litert-lm — model catalog
//
// A small, memory-aware registry of LiteRT-LM models that Easy mode knows how
// to download and run safely on iPhone. The point of the catalog is that a
// developer picks a case (`.gemma4_E2B`) and the package owns every
// device-safety decision — which file to fetch, how much RAM it needs, and a
// conservative vision-token budget that keeps the GPU working set under the
// jetsam ceiling.

import Foundation
import LiteRTLM

/// Which multimodal towers to initialize alongside the text decoder.
///
/// Each enabled tower costs memory and adds to engine init time, so Easy mode
/// only spins up what you ask for. Text generation is always available.
public struct Modality: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// Image understanding (vision tower). Gemma 4 E2B supports this on iOS.
  public static let vision = Modality(rawValue: 1 << 0)
  /// Audio understanding (Conformer tower).
  public static let audio = Modality(rawValue: 1 << 1)

  /// Text + image — the default for the 10-minute on-ramp.
  public static let textImage: Modality = [.vision]
  /// Text + image + audio.
  public static let all: Modality = [.vision, .audio]
}

/// A LiteRT-LM model Easy mode can download and run.
///
/// The catalog is intentionally tiny and curated for on-device safety rather
/// than being a mirror of every file on Hugging Face.
public enum LiteRTModel: String, CaseIterable, Sendable {
  /// Gemma 4 E2B (instruction-tuned), multimodal. The default hero model:
  /// ~2.6 GB on disk, comfortably under the iPhone jetsam ceiling, and the
  /// E2B variant whose vision path actually works on iOS.
  case gemma4_E2B

  // MARK: Download coordinates

  /// Hugging Face repository id hosting the `.litertlm` file.
  public var huggingFaceRepo: String {
    switch self {
    case .gemma4_E2B: return "litert-community/gemma-4-E2B-it-litert-lm"
    }
  }

  /// The `.litertlm` filename to fetch. We pick the generic mobile build; the
  /// vendor-tagged files (`*_Google_Tensor_G5`, `*_qualcomm_*`, `*_intel_*`)
  /// target specific NPUs and are not the right choice for Apple GPU.
  public var fileName: String {
    switch self {
    case .gemma4_E2B: return "gemma-4-E2B-it.litertlm"
    }
  }

  /// Approximate on-disk size in bytes (used for download UX and disk checks).
  public var approximateBytes: Int64 {
    switch self {
    case .gemma4_E2B: return 2_590_000_000
    }
  }

  // MARK: Device-safety defaults

  /// Modalities this model can serve.
  public var supportedModalities: Modality {
    switch self {
    case .gemma4_E2B: return .all
    }
  }

  /// Default modalities Easy mode brings up when the caller doesn't specify —
  /// kept to text+image so the first-token path stays light.
  public var defaultModalities: Modality {
    switch self {
    case .gemma4_E2B: return .textImage
    }
  }

  /// Backend for the vision tower. On iOS the Metal GPU delegate fails to prepare
  /// the vision encoder's STABLEHLO_COMPOSITE op (createConversation → INTERNAL
  /// error), so we run the encoder on CPU/XNNPACK. It's a ~224 MB graph invoked
  /// once per image, so CPU is acceptable. Verified on device (G0).
  public var visionBackend: Backend {
    switch self {
    case .gemma4_E2B: return .cpu()
    }
  }

  /// Backend for the audio tower. Gemma 4 E2B's audio encoder is *CPU-constrained*
  /// in the `.litertlm` (section_backend_constraint: cpu) — passing GPU makes the
  /// engine refuse to initialize. Verified on device (G0).
  public var audioBackend: Backend {
    switch self {
    case .gemma4_E2B: return .cpu()
    }
  }

  /// A conservative ceiling on the sum of input+output tokens (KV-cache size).
  /// Large enough for real chat, small enough to stay memory-safe on phones.
  public var defaultMaxTokens: Int {
    switch self {
    case .gemma4_E2B: return 2048
    }
  }

  /// Default per-image visual-token budget. Gemma 4 accepts 70/140/280/560/1120;
  /// 280 is a balanced default that caps vision memory without gutting quality.
  /// (See https://ai.google.dev/gemma/docs/capabilities/vision#variable-resolution)
  public var defaultVisualTokenBudget: Int32? {
    switch self {
    case .gemma4_E2B: return 280
    }
  }

  /// Minimum physical RAM (bytes) we consider safe to load this model on.
  /// Below this, Easy mode refuses rather than letting the OS jetsam mid-run.
  public var minimumDeviceRAM: Int64 {
    switch self {
    case .gemma4_E2B: return 7_000_000_000  // ~ comfortably above the 2.6 GB weights + working set
    }
  }

  /// The HF `resolve` URL for the model file (single-file download).
  public var downloadURL: URL {
    URL(string: "https://huggingface.co/\(huggingFaceRepo)/resolve/main/\(fileName)?download=true")!
  }
}
