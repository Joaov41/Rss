import CoreML
import Foundation
import Tokenizers

/// On-device LLM inference using CoreML with ANE optimization.
///
/// Supports both monolithic models (single .mlpackage) and chunked SWA models
/// (Gemma 4 E2B with 4 decode + 4 prefill chunks + external embeddings).
///
/// ```swift
/// let llm = try await CoreMLLLM.load(from: modelDirectory)
/// let answer = try await llm.generate("What is the capital of France?")
/// // → "The capital of France is **Paris**."
///
/// for await token in try await llm.stream("Tell me a story") {
///     print(token, terminator: "")
/// }
/// ```
public final class CoreMLLLM: @unchecked Sendable {
    private let tokenizer: any Tokenizer
    private let config: ModelConfig

    // Engine: exactly one of these is non-nil.
    private var chunkedEngine: ChunkedEngine?
    private var monolithicModel: MLModel?
    private var monolithicState: MLState?

    // Vision (lazy loaded to save memory)
    private var visionModel: MLModel?
    private var visionModelURL: URL?
    private var visionConfig: MLModelConfiguration?

    private init(config: ModelConfig, tokenizer: any Tokenizer) {
        self.config = config
        self.tokenizer = tokenizer
    }

    // MARK: - Public API

    /// Load a model from a local directory.
    ///
    /// Auto-detects layout:
    /// - If `chunk1.mlmodelc` exists → chunked SWA engine (Gemma 4 E2B)
    /// - Otherwise → monolithic model (`model.mlpackage` / `model.mlmodelc`)
    ///
    /// - Parameters:
    ///   - directory: Folder containing model files, embeddings, config
    ///   - computeUnits: CoreML compute units (default: `.cpuAndNeuralEngine`)
    public static func load(
        from directory: URL,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) async throws -> CoreMLLLM {
        var config = try ModelConfig.load(from: directory)

        // Tokenizer
        let tokDir = directory.appendingPathComponent("hf_model")
        let tokenizer = try await AutoTokenizer.from(modelFolder: tokDir)

        // Auto-detect: chunked or monolithic
        let isChunked = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("chunk1.mlmodelc").path)
            || FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("chunk1.mlpackage").path)

        let llm = CoreMLLLM(config: config, tokenizer: tokenizer)

        if isChunked {
            config = try runtimeAdjustedChunkedConfig(from: directory, base: config, computeUnits: computeUnits)
        } else {
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = computeUnits
            let modelURL = directory.appendingPathComponent("model.mlmodelc")
            if FileManager.default.fileExists(atPath: modelURL.path) {
                llm.monolithicModel = try MLModel(contentsOf: modelURL, configuration: mlConfig)
            } else {
                let pkgURL = directory.appendingPathComponent("model.mlpackage")
                let compiled = try await MLModel.compileModel(at: pkgURL)
                llm.monolithicModel = try MLModel(contentsOf: compiled, configuration: mlConfig)
            }
            if let model = llm.monolithicModel {
                config = runtimeAdjustedConfig(from: model, base: config)
            }
        }

        let adjustedLLM = CoreMLLLM(config: config, tokenizer: tokenizer)
        adjustedLLM.visionModelURL = llm.visionModelURL
        adjustedLLM.visionConfig = llm.visionConfig

        if isChunked {
            adjustedLLM.chunkedEngine = try await ChunkedEngine.load(
                from: directory, config: config, computeUnits: computeUnits)
        } else {
            adjustedLLM.monolithicModel = llm.monolithicModel
            adjustedLLM.monolithicState = adjustedLLM.monolithicModel?.makeState()
        }

        // Vision model (optional, lazy loaded on first image)
        let visionCompiled = directory.appendingPathComponent("vision.mlmodelc")
        let visionPkg = directory.appendingPathComponent("vision.mlpackage")
        if FileManager.default.fileExists(atPath: visionCompiled.path) {
            adjustedLLM.visionModelURL = visionCompiled
        } else if FileManager.default.fileExists(atPath: visionPkg.path) {
            adjustedLLM.visionModelURL = visionPkg
        }
        if adjustedLLM.visionModelURL != nil {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuAndGPU
            adjustedLLM.visionConfig = cfg
        }

        return adjustedLLM
    }

    private static func runtimeAdjustedChunkedConfig(
        from directory: URL,
        base: ModelConfig,
        computeUnits: MLComputeUnits
    ) throws -> ModelConfig {
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = computeUnits
        let chunkURL: URL
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("chunk1.mlmodelc").path) {
            chunkURL = directory.appendingPathComponent("chunk1.mlmodelc")
        } else {
            chunkURL = directory.appendingPathComponent("chunk1.mlpackage")
        }
        let chunk1 = try MLModel(contentsOf: chunkURL, configuration: mlConfig)
        return runtimeAdjustedConfig(from: chunk1, base: base)
    }

    private static func runtimeAdjustedConfig(from model: MLModel, base: ModelConfig) -> ModelConfig {
        let inputs = model.modelDescription.inputDescriptionsByName
        let inferredContext = inferSequenceLength(
            inputs["causal_mask"]?.multiArrayConstraint?.shape
                ?? inputs["causal_mask_full"]?.multiArrayConstraint?.shape
        ) ?? inputs["K_full_in"]?.multiArrayConstraint?.shape[safe: 2]?.intValue
        let inferredSliding = inferSequenceLength(inputs["causal_mask_sliding"]?.multiArrayConstraint?.shape)
            ?? inputs["K_sliding_in"]?.multiArrayConstraint?.shape[safe: 2]?.intValue
        return base.withRuntimeOverrides(contextLength: inferredContext, slidingWindow: inferredSliding)
    }

    private static func inferSequenceLength(_ shape: [NSNumber]?) -> Int? {
        guard let shape, !shape.isEmpty else { return nil }
        return shape.last?.intValue
    }

    /// Whether this model supports image input.
    public var supportsVision: Bool { visionModelURL != nil }

    /// Model name from config.
    public var modelName: String { config.modelName }

    /// Generate a complete response.
    public func generate(_ prompt: String, attachments: [PromptAttachment] = [],
                         image: CGImage? = nil,
                         maxTokens: Int = 256) async throws -> String {
        var result = ""
        for await token in try await stream(prompt, attachments: attachments,
                                           image: image, maxTokens: maxTokens) {
            result += token
        }
        return result
    }

    /// Stream tokens as they're generated.
    public func stream(_ prompt: String, attachments: [PromptAttachment] = [],
                       image: CGImage? = nil,
                       maxTokens: Int = 256) async throws -> AsyncStream<String> {
        let userPrompt = composePromptText(prompt, attachments: attachments)
        let chatPrompt = buildPrompt(userPrompt, hasImage: image != nil)
        let tokenIDs = tokenizer.encode(text: chatPrompt)

        var imageFeatures: MLMultiArray?
        if let image {
            imageFeatures = try processImage(image)
        }

        reset()

        let mutableSelf = self
        let features = imageFeatures
        let tokens = tokenIDs

        return AsyncStream { continuation in
            Task {
                do {
                    let IMAGE_TOKEN_ID = 258880
                    var imageIdx = 0
                    var nextID = 0

                    if let engine = mutableSelf.chunkedEngine {
                        // Chunked path: hybrid prefill + decode
                        let prefillLen = min(tokens.count, engine.prefillN)
                        let useHybrid = engine.hasPrefill && prefillLen > 0

                        if useHybrid {
                            try autoreleasepool {
                                let batch = Array(tokens[0..<prefillLen])
                                nextID = try engine.runPrefill(tokenIDs: batch,
                                                               imageFeatures: features)
                            }
                            imageIdx = tokens[0..<prefillLen].filter { $0 == IMAGE_TOKEN_ID }.count
                            engine.currentPosition = prefillLen

                            // Per-token decode for remaining prompt tokens
                            for step in prefillLen..<tokens.count {
                                let tid = tokens[step]
                                try autoreleasepool {
                                    if tid == IMAGE_TOKEN_ID, let feats = features, imageIdx < 256 {
                                        let imgEmb = engine.sliceFeature(feats, at: imageIdx)
                                        nextID = try engine.predictStep(tokenID: 0, position: step,
                                                                         imageEmbedding: imgEmb)
                                        imageIdx += 1
                                    } else {
                                        nextID = try engine.predictStep(tokenID: tid, position: step)
                                    }
                                }
                                engine.currentPosition = step + 1
                            }
                        } else {
                            for (step, tid) in tokens.enumerated() {
                                try autoreleasepool {
                                    if tid == IMAGE_TOKEN_ID, let feats = features, imageIdx < 256 {
                                        let imgEmb = engine.sliceFeature(feats, at: imageIdx)
                                        nextID = try engine.predictStep(tokenID: 0, position: step,
                                                                         imageEmbedding: imgEmb)
                                        imageIdx += 1
                                    } else {
                                        nextID = try engine.predictStep(tokenID: tid, position: step)
                                    }
                                }
                                engine.currentPosition = step + 1
                            }
                        }

                        // Decode loop
                        let eosIDs: Set<Int> = [1, 106, 151645]
                        for _ in 0..<maxTokens {
                            if eosIDs.contains(nextID) { break }
                            if engine.currentPosition >= mutableSelf.config.contextLength { break }
                            let text = mutableSelf.tokenizer.decode(tokens: [nextID])
                            continuation.yield(text)
                            try autoreleasepool {
                                nextID = try engine.predictStep(tokenID: nextID,
                                                                 position: engine.currentPosition)
                            }
                            engine.currentPosition += 1
                        }
                    } else {
                        // Monolithic path
                        for (step, tid) in tokens.enumerated() {
                            if tid == IMAGE_TOKEN_ID, let feats = features, imageIdx < 256 {
                                let imgEmb = ImageProcessor.sliceFeature(feats, at: imageIdx,
                                    hiddenSize: mutableSelf.config.hiddenSize)
                                nextID = try mutableSelf.predictMonolithic(
                                    tokenID: 0, position: step, imageEmbedding: imgEmb)
                                imageIdx += 1
                            } else {
                                nextID = try mutableSelf.predictMonolithic(
                                    tokenID: tid, position: step)
                            }
                        }
                        let eosIDs: Set<Int> = [1, 106, 151645]
                        var pos = tokens.count
                        for _ in 0..<maxTokens {
                            if eosIDs.contains(nextID) { break }
                            let text = mutableSelf.tokenizer.decode(tokens: [nextID])
                            continuation.yield(text)
                            nextID = try mutableSelf.predictMonolithic(
                                tokenID: nextID, position: pos)
                            pos += 1
                        }
                    }
                } catch {}
                continuation.finish()
            }
        }
    }

    /// Reset conversation state (clears KV cache).
    public func reset() {
        if let engine = chunkedEngine {
            engine.reset()
        } else {
            monolithicState = monolithicModel?.makeState()
        }
    }

    // MARK: - Private: monolithic prediction

    private func predictMonolithic(tokenID: Int, position: Int,
                                    imageEmbedding: MLMultiArray? = nil) throws -> Int {
        guard let model = monolithicModel, let state = monolithicState else {
            throw CoreMLLLMError.predictionFailed
        }
        let ctx = maskSequenceLength(for: model, inputName: "causal_mask") ?? config.contextLength
        let hs = config.hiddenSize

        let ids = try MLMultiArray(shape: [1, 1], dataType: .int32)
        ids[[0, 0] as [NSNumber]] = NSNumber(value: Int32(tokenID))
        let pos = try MLMultiArray(shape: [1], dataType: .int32)
        pos[0] = NSNumber(value: Int32(position))
        let mask = try MLMultiArray(shape: [1, 1, 1, NSNumber(value: ctx)], dataType: .float16)
        let mp = mask.dataPointer.bindMemory(to: UInt16.self, capacity: ctx)
        for i in 0..<ctx { mp[i] = i <= position ? 0 : 0xFC00 }
        let umask = try MLMultiArray(shape: [1, 1, NSNumber(value: ctx), 1], dataType: .float16)
        let up = umask.dataPointer.bindMemory(to: UInt16.self, capacity: ctx)
        memset(up, 0, ctx * MemoryLayout<UInt16>.stride)
        up[min(position, ctx - 1)] = 0x3C00

        var dict: [String: MLFeatureValue] = [
            "input_ids": MLFeatureValue(multiArray: ids),
            "position_ids": MLFeatureValue(multiArray: pos),
            "causal_mask": MLFeatureValue(multiArray: mask),
            "update_mask": MLFeatureValue(multiArray: umask),
        ]

        let inputNames = model.modelDescription.inputDescriptionsByName
        if inputNames["per_layer_combined"] != nil, let engine = chunkedEngine {
            let emb = try engine.computePerLayerCombined(tokenID: tokenID,
                embedding: try MLMultiArray(shape: [1, 1, NSNumber(value: hs)], dataType: .float16))
            dict["per_layer_combined"] = MLFeatureValue(multiArray: emb)
        }
        if inputNames["image_embedding"] != nil {
            let imgEmb: MLMultiArray
            if let imageEmbedding { imgEmb = imageEmbedding }
            else {
                imgEmb = try MLMultiArray(shape: [1, 1, NSNumber(value: hs)], dataType: .float16)
                memset(imgEmb.dataPointer, 0, hs * MemoryLayout<UInt16>.stride)
            }
            dict["image_embedding"] = MLFeatureValue(multiArray: imgEmb)
        }

        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: dict),
                                           using: state)
        return output.featureValue(for: "token_id")!.multiArrayValue![0].intValue
    }

    // MARK: - Private: vision

    private func processImage(_ image: CGImage) throws -> MLMultiArray {
        if visionModel == nil, let url = visionModelURL, let cfg = visionConfig {
            visionModel = try MLModel(contentsOf: url, configuration: cfg)
        }
        guard let vm = visionModel else { throw CoreMLLLMError.visionNotAvailable }
        return try ImageProcessor.process(image, with: vm)
    }

    // MARK: - Private: prompt building

    private func composePromptText(_ text: String, attachments: [PromptAttachment]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return trimmed }

        let renderedAttachments = attachments
            .map { attachment in
                let body = attachment.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return "[Attached file: \(attachment.filename)]\n\(body)"
            }
            .joined(separator: "\n\n")

        if trimmed.isEmpty {
            return "Use the attached file content below.\n\n\(renderedAttachments)"
        }

        return "\(trimmed)\n\nAttached file content:\n\n\(renderedAttachments)"
    }

    private func buildPrompt(_ text: String, hasImage: Bool) -> String {
        if config.architecture.hasPrefix("qwen") {
            return "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n"
        }
        if hasImage {
            let imageTokens = String(repeating: "<|image|>", count: 256)
            return "<bos><|turn>user\n<|image>\(imageTokens)<image|>\n\(text)<turn|>\n<|turn>model\n"
        }
        return "<bos><|turn>user\n\(text)<turn|>\n<|turn>model\n"
    }
}

// MARK: - Error types

public enum CoreMLLLMError: LocalizedError {
    case configNotFound
    case predictionFailed
    case modelNotFound(String)
    case prefillNotAvailable
    case visionNotAvailable

    public var errorDescription: String? {
        switch self {
        case .configNotFound: return "model_config.json not found"
        case .predictionFailed: return "Model prediction failed"
        case .modelNotFound(let name): return "Model file not found: \(name)"
        case .prefillNotAvailable: return "Prefill chunks not loaded"
        case .visionNotAvailable: return "Vision model not available"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private func maskSequenceLength(for model: MLModel, inputName: String) -> Int? {
    guard
        let shape = model.modelDescription.inputDescriptionsByName[inputName]?.multiArrayConstraint?.shape,
        shape.count == 4
    else {
        return nil
    }
    return max(shape[2].intValue, shape[3].intValue)
}
