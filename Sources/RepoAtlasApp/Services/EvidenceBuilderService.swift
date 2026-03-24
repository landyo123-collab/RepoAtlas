import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Evidence Builder OpenAI Client

/// Thin OpenAI chat-completions client that returns structured JSON.
/// Used exclusively by EvidenceBuilderOrchestrator for multi-pass evidence building.
struct EvidenceBuilderService {

    enum ServiceError: LocalizedError {
        case notConfigured
        case invalidURL
        case badResponse(status: Int, message: String)
        case noContent
        case jsonParseFailed(String)
        case modelUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Evidence builder not configured (missing OpenAI API key)."
            case .invalidURL: return "Invalid OpenAI API URL."
            case .badResponse(let s, let m): return "Evidence builder request failed (\(s)): \(m)"
            case .noContent: return "Evidence builder returned no content."
            case .jsonParseFailed(let m): return "Evidence builder JSON parse failed: \(m)"
            case .modelUnavailable(let m): return "Model unavailable: \(m)"
            }
        }
    }

    // MARK: - Structured JSON request

    /// Send a chat completion request to OpenAI and return the raw JSON string.
    /// Uses `response_format: { type: "json_object" }` to enforce JSON output.
    func requestJSON(
        systemPrompt: String,
        userPrompt: String,
        configuration: EvidenceBuilderConfiguration,
        maxTokens: Int = 4096,
        temperature: Double = 0.1
    ) async throws -> String {
        guard configuration.isAvailable else {
            throw ServiceError.notConfigured
        }

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw ServiceError.invalidURL
        }

        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? EvidenceBuilderConfiguration.defaultModel
            : configuration.model

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": temperature,
            "max_tokens": maxTokens,
            "response_format": ["type": "json_object"]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.badResponse(status: -1, message: "No HTTP response")
        }

        // If model not found, try fallback
        if http.statusCode == 404 || http.statusCode == 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("model") && body.contains("not found") || body.contains("does not exist") {
                throw ServiceError.modelUnavailable(model)
            }
        }

        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ServiceError.badResponse(status: http.statusCode, message: message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError.noContent
        }

        return content
    }

    // MARK: - Typed JSON request with automatic decode

    /// Send a request and decode the response into a Codable type.
    func request<T: Codable>(
        systemPrompt: String,
        userPrompt: String,
        configuration: EvidenceBuilderConfiguration,
        maxTokens: Int = 4096,
        temperature: Double = 0.1,
        as type: T.Type
    ) async throws -> T {
        let raw = try await requestJSON(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            configuration: configuration,
            maxTokens: maxTokens,
            temperature: temperature
        )

        guard let data = raw.data(using: .utf8) else {
            throw ServiceError.jsonParseFailed("Could not encode response to UTF-8")
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ServiceError.jsonParseFailed("Decode error: \(error.localizedDescription)\nRaw: \(raw.prefix(500))")
        }
    }

    // MARK: - Request with model fallback

    /// Try the configured model first; if unavailable, fall back to the fallback model.
    func requestWithFallback<T: Codable>(
        systemPrompt: String,
        userPrompt: String,
        configuration: EvidenceBuilderConfiguration,
        maxTokens: Int = 4096,
        temperature: Double = 0.1,
        as type: T.Type
    ) async throws -> (result: T, modelUsed: String, usedFallback: Bool) {
        do {
            let result = try await request(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                configuration: configuration,
                maxTokens: maxTokens,
                temperature: temperature,
                as: type
            )
            let model = configuration.model.isEmpty ? EvidenceBuilderConfiguration.defaultModel : configuration.model
            return (result, model, false)
        } catch ServiceError.modelUnavailable {
            // Try fallback model
            var fallbackConfig = configuration
            fallbackConfig.model = EvidenceBuilderConfiguration.fallbackModel
            let result = try await request(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                configuration: fallbackConfig,
                maxTokens: maxTokens,
                temperature: temperature,
                as: type
            )
            return (result, EvidenceBuilderConfiguration.fallbackModel, true)
        }
    }
}
