import Foundation

/// Configuration for the OpenAI Evidence Builder subsystem.
struct EvidenceBuilderConfiguration: Codable, Equatable {
    var apiKey: String
    var model: String
    var isEnabled: Bool
    var maxPasses: Int
    var maxCandidates: Int
    var maxBatches: Int
    var maxDossierTokens: Int

    var isAvailable: Bool {
        isEnabled && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let disabled = EvidenceBuilderConfiguration(
        apiKey: "",
        model: "gpt-4.1-mini",
        isEnabled: false,
        maxPasses: 3,
        maxCandidates: 2000,
        maxBatches: 16,
        maxDossierTokens: 100_000
    )

    static let defaultModel = "gpt-4.1-mini"
    static let fallbackModel = "gpt-4.1-nano"
}
