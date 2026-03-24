import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DeepSeekService {
    enum DeepSeekError: LocalizedError {
        case missingAPIKey
        case invalidBaseURL
        case badResponse(status: Int, message: String)
        case noContent

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "DeepSeek API key not configured. Add it in Settings or ~/.repoatlas.env."
            case .invalidBaseURL:
                return "DeepSeek base URL is invalid."
            case let .badResponse(status, message):
                return "DeepSeek request failed (\(status)): \(message)"
            case .noContent:
                return "DeepSeek returned no answer content."
            }
        }
    }

    func ask(prompt: String, configuration: DeepSeekConfiguration) async throws -> String {
        guard configuration.isConfigured else {
            throw DeepSeekError.missingAPIKey
        }

        let trimmedBase = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedBase + "/chat/completions") else {
            throw DeepSeekError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let payload = ChatCompletionRequest(
            model: configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "deepseek-chat" : configuration.model,
            messages: [
                ChatMessage(role: "system", content: "You answer repo questions thoroughly and precisely. You have been given comprehensive context including a complete file manifest and detailed evidence slices. Cite file paths and line numbers from the provided context. Answer confidently from what you have."),
                ChatMessage(role: "user", content: prompt)
            ],
            temperature: 0.2,
            stream: false
        )

        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekError.badResponse(status: -1, message: "No HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw DeepSeekError.badResponse(status: http.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw DeepSeekError.noContent
        }
        return content
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let stream: Bool
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: AssistantMessage
    }

    struct AssistantMessage: Decodable {
        let content: String?
    }
}
