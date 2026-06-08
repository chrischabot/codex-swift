import Foundation

#if CODEXKIT_MLX && canImport(MLX) && canImport(MLXNN) && canImport(MLXEmbedders) && canImport(MLXLMCommon)
import MLX
import MLXNN
import MLXEmbedders
import MLXLMCommon

final class BGERerankerClassificationHead: Module {
    @ModuleInfo(key: "dense") private var dense: Linear
    @ModuleInfo(key: "out_proj") private var outProj: Linear

    init(hiddenSize: Int) {
        _dense.wrappedValue = Linear(hiddenSize, hiddenSize)
        _outProj.wrappedValue = Linear(hiddenSize, 1)
    }

    func callAsFunction(_ features: MLXArray) -> MLXArray {
        outProj(tanh(dense(features)))
    }
}

final class BGERerankerModel: Module, EmbeddingModel {
    @ModuleInfo(key: "bert") private var bert: BertModel
    @ModuleInfo(key: "classifier") private var classifier: BGERerankerClassificationHead

    public let vocabularySize: Int

    init(configurationData: Data) throws {
        let bertConfig = try JSONDecoder.json5().decode(BertConfiguration.self,
                                                        from: configurationData)
        let rerankerConfig = try JSONDecoder.json5().decode(
            BGERerankerConfiguration.self, from: configurationData)
        _bert.wrappedValue = BertModel(bertConfig)
        _classifier.wrappedValue = BGERerankerClassificationHead(
            hiddenSize: rerankerConfig.hiddenSize)
        self.vocabularySize = rerankerConfig.vocabularySize
    }

    func score(_ inputs: MLXArray,
               tokenTypeIds: MLXArray? = nil,
               attentionMask: MLXArray? = nil) -> MLXArray {
        let output = bert(inputs,
                          positionIds: nil,
                          tokenTypeIds: tokenTypeIds,
                          attentionMask: attentionMask)
        guard let hiddenStates = output.hiddenStates else {
            return MLXArray([Float(0)])
        }
        let cls = hiddenStates[0..., 0]
        return classifier(cls).squeezed(axis: -1)
    }

    func callAsFunction(_ inputs: MLXArray,
                        positionIds: MLXArray?,
                        tokenTypeIds: MLXArray?,
                        attentionMask: MLXArray?) -> EmbeddingModelOutput {
        bert(inputs,
             positionIds: positionIds,
             tokenTypeIds: tokenTypeIds,
             attentionMask: attentionMask)
    }

    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var remapped: [String: MLXArray] = [:]
        for (rawKey, value) in weights {
            guard rawKey != "__metadata__" else { continue }
            if rawKey.hasPrefix("classifier.") {
                remapped[rawKey] = value
                continue
            }
            guard let stripped = stripEncoderPrefix(rawKey) else { continue }
            let sanitized = bert.sanitize(weights: [stripped: value])
            for (key, sanitizedValue) in sanitized {
                remapped["bert.\(key)"] = sanitizedValue
            }
        }
        return remapped
    }

    private func stripEncoderPrefix(_ key: String) -> String? {
        for prefix in ["roberta.", "bert.", "xlm_roberta.", "xlm-roberta.", "model."] {
            if key.hasPrefix(prefix) {
                return String(key.dropFirst(prefix.count))
            }
        }
        if key.hasPrefix("embeddings.") || key.hasPrefix("encoder.") || key.hasPrefix("pooler.") {
            return key
        }
        return nil
    }
}

private struct BGERerankerConfiguration: Decodable {
    var hiddenSize: Int
    var vocabularySize: Int

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case distilHiddenSize = "dim"
        case vocabularySize = "vocab_size"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenSize = try container.decodeIfPresent(Int.self, forKey: .hiddenSize)
            ?? container.decodeIfPresent(Int.self, forKey: .distilHiddenSize)
            ?? 1024
        vocabularySize = try container.decodeIfPresent(Int.self, forKey: .vocabularySize)
            ?? 250_002
    }
}

enum BGERerankerFactory {
    static let shared: EmbedderModelFactory = {
        let registry = ModelTypeRegistry<any EmbeddingModel>(creators: [
            "xlm-roberta": { try BGERerankerModel(configurationData: $0) },
            "roberta": { try BGERerankerModel(configurationData: $0) },
            "bert": { try BGERerankerModel(configurationData: $0) },
        ])
        return EmbedderModelFactory(typeRegistry: registry,
                                    modelRegistry: EmbedderRegistry.shared)
    }()
}
#endif
