import Foundation

/// Model configuration loaded from model_config.json.
public struct ModelConfig: Sendable {
    public let modelName: String
    public let architecture: String
    public let hiddenSize: Int
    public let contextLength: Int
    public let vocabSize: Int
    public let bosTokenId: Int
    public let eosTokenId: Int

    // Gemma 4 specific (defaults match Gemma 4 E2B).
    public let perLayerDim: Int
    public let numLayers: Int
    public let slidingWindow: Int
    public let embedScale: Float
    public let perLayerProjScale: Float
    public let perLayerInputScale: Float
    public let perLayerEmbedScale: Float

    init(
        modelName: String,
        architecture: String,
        hiddenSize: Int,
        contextLength: Int,
        vocabSize: Int,
        bosTokenId: Int,
        eosTokenId: Int,
        perLayerDim: Int,
        numLayers: Int,
        slidingWindow: Int,
        embedScale: Float,
        perLayerProjScale: Float,
        perLayerInputScale: Float,
        perLayerEmbedScale: Float
    ) {
        self.modelName = modelName
        self.architecture = architecture
        self.hiddenSize = hiddenSize
        self.contextLength = contextLength
        self.vocabSize = vocabSize
        self.bosTokenId = bosTokenId
        self.eosTokenId = eosTokenId
        self.perLayerDim = perLayerDim
        self.numLayers = numLayers
        self.slidingWindow = slidingWindow
        self.embedScale = embedScale
        self.perLayerProjScale = perLayerProjScale
        self.perLayerInputScale = perLayerInputScale
        self.perLayerEmbedScale = perLayerEmbedScale
    }

    func withRuntimeOverrides(contextLength: Int? = nil, slidingWindow: Int? = nil) -> ModelConfig {
        ModelConfig(
            modelName: modelName,
            architecture: architecture,
            hiddenSize: hiddenSize,
            contextLength: contextLength ?? self.contextLength,
            vocabSize: vocabSize,
            bosTokenId: bosTokenId,
            eosTokenId: eosTokenId,
            perLayerDim: perLayerDim,
            numLayers: numLayers,
            slidingWindow: slidingWindow ?? self.slidingWindow,
            embedScale: embedScale,
            perLayerProjScale: perLayerProjScale,
            perLayerInputScale: perLayerInputScale,
            perLayerEmbedScale: perLayerEmbedScale
        )
    }

    public static func load(from directory: URL) throws -> ModelConfig {
        let url = directory.appendingPathComponent("model_config.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoreMLLLMError.configNotFound
        }
        return ModelConfig(
            modelName: json["model_name"] as? String ?? "Model",
            architecture: json["architecture"] as? String ?? "gemma4",
            hiddenSize: json["hidden_size"] as? Int ?? 1536,
            contextLength: json["context_length"] as? Int ?? 2048,
            vocabSize: json["vocab_size"] as? Int ?? 262144,
            bosTokenId: json["bos_token_id"] as? Int ?? 2,
            eosTokenId: json["eos_token_id"] as? Int ?? 1,
            perLayerDim: json["per_layer_dim"] as? Int ?? 256,
            numLayers: json["num_layers"] as? Int ?? 35,
            slidingWindow: json["sliding_window"] as? Int ?? 512,
            embedScale: Float(json["embed_scale"] as? Double ?? 39.19),
            perLayerProjScale: Float(json["per_layer_model_projection_scale"] as? Double ?? 0.0255),
            perLayerInputScale: Float(json["per_layer_input_scale"] as? Double ?? 0.707),
            perLayerEmbedScale: Float(json["per_layer_embed_scale"] as? Double ?? 16.0)
        )
    }
}
