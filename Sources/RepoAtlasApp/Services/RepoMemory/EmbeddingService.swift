import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Embedding configuration

struct EmbeddingConfiguration {
    var apiKey: String
    var model: String
    var isEnabled: Bool

    var isAvailable: Bool {
        isEnabled && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let disabled = EmbeddingConfiguration(apiKey: "", model: "text-embedding-3-small", isEnabled: false)
}

// MARK: - Embedding result

struct EmbeddingVector {
    let values: [Float]
    let model: String
    let tokenCount: Int

    var dimension: Int { values.count }

    /// Cosine similarity with another vector of the same dimension.
    func cosineSimilarity(with other: EmbeddingVector) -> Float {
        guard values.count == other.values.count, !values.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<values.count {
            dot += values[i] * other.values[i]
            normA += values[i] * values[i]
            normB += other.values[i] * other.values[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}

// MARK: - Embedding service

struct EmbeddingService {
    enum EmbeddingError: LocalizedError {
        case notConfigured
        case invalidURL
        case badResponse(status: Int, message: String)
        case noEmbedding
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OpenAI embeddings not configured."
            case .invalidURL: return "Invalid OpenAI API URL."
            case .badResponse(let s, let m): return "Embedding request failed (\(s)): \(m)"
            case .noEmbedding: return "No embedding returned."
            case .decodingFailed(let m): return "Embedding decode failed: \(m)"
            }
        }
    }

    /// Embed a single text string.
    func embed(text: String, configuration: EmbeddingConfiguration) async throws -> EmbeddingVector {
        let results = try await embedBatch(texts: [text], configuration: configuration)
        guard let first = results.first else { throw EmbeddingError.noEmbedding }
        return first
    }

    /// Embed a batch of texts (up to ~2048 at a time per OpenAI limits).
    func embedBatch(texts: [String], configuration: EmbeddingConfiguration) async throws -> [EmbeddingVector] {
        guard configuration.isAvailable else { throw EmbeddingError.notConfigured }

        guard let url = URL(string: "https://api.openai.com/v1/embeddings") else {
            throw EmbeddingError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let model = configuration.model.isEmpty ? "text-embedding-3-small" : configuration.model

        // Truncate very long texts to avoid token limits
        let truncated = texts.map { String($0.prefix(8000)) }

        let payload: [String: Any] = [
            "model": model,
            "input": truncated
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingError.badResponse(status: -1, message: "No HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw EmbeddingError.badResponse(status: http.statusCode, message: message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw EmbeddingError.decodingFailed("Could not parse response")
        }

        let modelUsed = json["model"] as? String ?? model
        let usage = json["usage"] as? [String: Any]
        let totalTokens = usage?["total_tokens"] as? Int ?? 0
        let tokensPerItem = texts.isEmpty ? 0 : totalTokens / texts.count

        var results: [EmbeddingVector] = []
        // Sort by index to ensure correct ordering
        let sorted = dataArray.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        for item in sorted {
            guard let embedding = item["embedding"] as? [NSNumber] else {
                throw EmbeddingError.decodingFailed("Missing embedding array")
            }
            let floats = embedding.map { $0.floatValue }
            results.append(EmbeddingVector(values: floats, model: modelUsed, tokenCount: tokensPerItem))
        }

        return results
    }
}
