import Foundation
import Combine

struct DeepSeekConfiguration: Codable, Equatable {
    var apiKey: String
    var baseURL: String
    var model: String

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
final class DeepSeekConfigManager: ObservableObject {
    @Published var configuration: DeepSeekConfiguration
    @Published var embeddingConfiguration: EmbeddingConfiguration
    @Published var evidenceBuilderConfiguration: EvidenceBuilderConfiguration

    private let defaults = UserDefaults.standard
    private let keyName = "RepoAtlas.DeepSeek.apiKey"
    private let baseURLName = "RepoAtlas.DeepSeek.baseURL"
    private let modelName = "RepoAtlas.DeepSeek.model"

    private let embKeyName = "RepoAtlas.OpenAI.apiKey"
    private let embModelName = "RepoAtlas.OpenAI.embeddingModel"
    private let embEnabledName = "RepoAtlas.OpenAI.embeddingsEnabled"

    private let ebEnabledName = "RepoAtlas.EvidenceBuilder.enabled"
    private let ebModelName = "RepoAtlas.EvidenceBuilder.model"
    private let ebMaxPassesName = "RepoAtlas.EvidenceBuilder.maxPasses"
    private let ebMaxCandidatesName = "RepoAtlas.EvidenceBuilder.maxCandidates"
    private let ebMaxBatchesName = "RepoAtlas.EvidenceBuilder.maxBatches"
    private let ebMaxDossierTokensName = "RepoAtlas.EvidenceBuilder.maxDossierTokens"

    init() {
        self.configuration = Self.loadConfiguration(from: UserDefaults.standard)
        self.embeddingConfiguration = Self.loadEmbeddingConfiguration(from: UserDefaults.standard)
        self.evidenceBuilderConfiguration = Self.loadEvidenceBuilderConfiguration(from: UserDefaults.standard)
    }

    func save(apiKey: String, baseURL: String, model: String) {
        defaults.set(apiKey, forKey: keyName)
        defaults.set(baseURL, forKey: baseURLName)
        defaults.set(model, forKey: modelName)
        configuration = DeepSeekConfiguration(apiKey: apiKey, baseURL: baseURL, model: model)
    }

    func saveEmbedding(apiKey: String, model: String, enabled: Bool) {
        defaults.set(apiKey, forKey: embKeyName)
        defaults.set(model, forKey: embModelName)
        defaults.set(enabled, forKey: embEnabledName)
        embeddingConfiguration = EmbeddingConfiguration(apiKey: apiKey, model: model, isEnabled: enabled)
    }

    func saveEvidenceBuilder(enabled: Bool, model: String, maxPasses: Int, maxCandidates: Int, maxBatches: Int, maxDossierTokens: Int) {
        defaults.set(enabled, forKey: ebEnabledName)
        defaults.set(model, forKey: ebModelName)
        defaults.set(maxPasses, forKey: ebMaxPassesName)
        defaults.set(maxCandidates, forKey: ebMaxCandidatesName)
        defaults.set(maxBatches, forKey: ebMaxBatchesName)
        defaults.set(maxDossierTokens, forKey: ebMaxDossierTokensName)
        evidenceBuilderConfiguration = EvidenceBuilderConfiguration(
            apiKey: embeddingConfiguration.apiKey,
            model: model,
            isEnabled: enabled,
            maxPasses: maxPasses,
            maxCandidates: maxCandidates,
            maxBatches: maxBatches,
            maxDossierTokens: maxDossierTokens
        )
    }

    func reload() {
        configuration = Self.loadConfiguration(from: defaults)
        embeddingConfiguration = Self.loadEmbeddingConfiguration(from: defaults)
        evidenceBuilderConfiguration = Self.loadEvidenceBuilderConfiguration(from: defaults)
    }

    private static func loadConfiguration(from defaults: UserDefaults) -> DeepSeekConfiguration {
        let persisted = DeepSeekConfiguration(
            apiKey: defaults.string(forKey: "RepoAtlas.DeepSeek.apiKey") ?? "",
            baseURL: defaults.string(forKey: "RepoAtlas.DeepSeek.baseURL") ?? "https://api.deepseek.com",
            model: defaults.string(forKey: "RepoAtlas.DeepSeek.model") ?? "deepseek-chat"
        )

        if persisted.isConfigured {
            return persisted
        }

        if let envConfig = loadFromEnvFile() {
            return envConfig
        }

        let env = ProcessInfo.processInfo.environment
        return DeepSeekConfiguration(
            apiKey: env["DEEPSEEK_API_KEY"] ?? "",
            baseURL: env["DEEPSEEK_BASE_URL"] ?? "https://api.deepseek.com",
            model: env["DEEPSEEK_MODEL"] ?? "deepseek-chat"
        )
    }

    private static func loadFromEnvFile() -> DeepSeekConfiguration? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".repoatlas.env"),
            home.appendingPathComponent("Library/Application Support/RepoAtlas/.env")
        ]

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let values = parseEnv(data)
            return DeepSeekConfiguration(
                apiKey: values["DEEPSEEK_API_KEY"] ?? "",
                baseURL: values["DEEPSEEK_BASE_URL"] ?? "https://api.deepseek.com",
                model: values["DEEPSEEK_MODEL"] ?? "deepseek-chat"
            )
        }

        return nil
    }

    private static func parseEnv(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            result[key] = value
        }

        return result
    }

    private static func loadEmbeddingConfiguration(from defaults: UserDefaults) -> EmbeddingConfiguration {
        let persisted = EmbeddingConfiguration(
            apiKey: defaults.string(forKey: "RepoAtlas.OpenAI.apiKey") ?? "",
            model: defaults.string(forKey: "RepoAtlas.OpenAI.embeddingModel") ?? "text-embedding-3-small",
            isEnabled: defaults.bool(forKey: "RepoAtlas.OpenAI.embeddingsEnabled")
        )

        if persisted.isAvailable {
            return persisted
        }

        // Try env file
        if let envConfig = loadEmbeddingFromEnvFile() {
            return envConfig
        }

        // Try process environment
        let env = ProcessInfo.processInfo.environment
        let key = env["OPENAI_API_KEY"] ?? ""
        let model = env["OPENAI_EMBEDDING_MODEL"] ?? "text-embedding-3-small"
        let enabledStr = env["OPENAI_EMBEDDINGS_ENABLED"] ?? "false"
        let enabled = enabledStr.lowercased() == "true" || enabledStr == "1"
        return EmbeddingConfiguration(apiKey: key, model: model, isEnabled: enabled)
    }

    private static func loadEmbeddingFromEnvFile() -> EmbeddingConfiguration? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".repoatlas.env"),
            home.appendingPathComponent("Library/Application Support/RepoAtlas/.env")
        ]

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let values = parseEnv(data)
            let key = values["OPENAI_API_KEY"] ?? ""
            guard !key.isEmpty else { continue }
            let model = values["OPENAI_EMBEDDING_MODEL"] ?? "text-embedding-3-small"
            let enabledStr = values["OPENAI_EMBEDDINGS_ENABLED"] ?? "false"
            let enabled = enabledStr.lowercased() == "true" || enabledStr == "1"
            return EmbeddingConfiguration(apiKey: key, model: model, isEnabled: enabled)
        }

        return nil
    }

    // MARK: - Evidence Builder Configuration

    private static func loadEvidenceBuilderConfiguration(from defaults: UserDefaults) -> EvidenceBuilderConfiguration {
        let enabled = defaults.bool(forKey: "RepoAtlas.EvidenceBuilder.enabled")
        let model = defaults.string(forKey: "RepoAtlas.EvidenceBuilder.model") ?? EvidenceBuilderConfiguration.defaultModel
        let maxPasses = defaults.integer(forKey: "RepoAtlas.EvidenceBuilder.maxPasses")
        let maxCandidates = defaults.integer(forKey: "RepoAtlas.EvidenceBuilder.maxCandidates")
        let maxBatches = defaults.integer(forKey: "RepoAtlas.EvidenceBuilder.maxBatches")
        let maxDossierTokens = defaults.integer(forKey: "RepoAtlas.EvidenceBuilder.maxDossierTokens")

        // Check if UserDefaults has evidence builder settings
        let hasPersistedSettings = defaults.object(forKey: "RepoAtlas.EvidenceBuilder.enabled") != nil

        if hasPersistedSettings {
            // Use the OpenAI API key from embedding config (shared)
            let embConfig = loadEmbeddingConfiguration(from: defaults)
            return EvidenceBuilderConfiguration(
                apiKey: embConfig.apiKey,
                model: model,
                isEnabled: enabled,
                maxPasses: maxPasses > 0 ? maxPasses : 3,
                maxCandidates: maxCandidates > 0 ? maxCandidates : 1500,
                maxBatches: maxBatches > 0 ? maxBatches : 12,
                maxDossierTokens: maxDossierTokens > 0 ? maxDossierTokens : 24_000
            )
        }

        // Try env file
        if let envConfig = loadEvidenceBuilderFromEnvFile() {
            return envConfig
        }

        // Try process environment
        let env = ProcessInfo.processInfo.environment
        let key = env["OPENAI_API_KEY"] ?? ""
        let enabledStr = env["OPENAI_EVIDENCE_BUILDER_ENABLED"] ?? "false"
        let envEnabled = enabledStr.lowercased() == "true" || enabledStr == "1"
        let envModel = env["OPENAI_EVIDENCE_BUILDER_MODEL"] ?? EvidenceBuilderConfiguration.defaultModel
        let envMaxPasses = Int(env["OPENAI_EVIDENCE_BUILDER_MAX_PASSES"] ?? "") ?? 3
        let envMaxCandidates = Int(env["OPENAI_EVIDENCE_BUILDER_MAX_CANDIDATES"] ?? "") ?? 1500
        let envMaxBatches = Int(env["OPENAI_EVIDENCE_BUILDER_MAX_BATCHES"] ?? "") ?? 12
        let envMaxDossierTokens = Int(env["OPENAI_EVIDENCE_BUILDER_MAX_DOSSIER_TOKENS"] ?? "") ?? 24_000
        return EvidenceBuilderConfiguration(
            apiKey: key,
            model: envModel,
            isEnabled: envEnabled,
            maxPasses: envMaxPasses,
            maxCandidates: envMaxCandidates,
            maxBatches: envMaxBatches,
            maxDossierTokens: envMaxDossierTokens
        )
    }

    private static func loadEvidenceBuilderFromEnvFile() -> EvidenceBuilderConfiguration? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".repoatlas.env"),
            home.appendingPathComponent("Library/Application Support/RepoAtlas/.env")
        ]

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let values = parseEnv(data)
            let key = values["OPENAI_API_KEY"] ?? ""
            guard !key.isEmpty else { continue }
            let enabledStr = values["OPENAI_EVIDENCE_BUILDER_ENABLED"] ?? "false"
            let enabled = enabledStr.lowercased() == "true" || enabledStr == "1"
            let model = values["OPENAI_EVIDENCE_BUILDER_MODEL"] ?? EvidenceBuilderConfiguration.defaultModel
            let maxPasses = Int(values["OPENAI_EVIDENCE_BUILDER_MAX_PASSES"] ?? "") ?? 3
            let maxCandidates = Int(values["OPENAI_EVIDENCE_BUILDER_MAX_CANDIDATES"] ?? "") ?? 1500
            let maxBatches = Int(values["OPENAI_EVIDENCE_BUILDER_MAX_BATCHES"] ?? "") ?? 12
            let maxDossierTokens = Int(values["OPENAI_EVIDENCE_BUILDER_MAX_DOSSIER_TOKENS"] ?? "") ?? 24_000
            return EvidenceBuilderConfiguration(
                apiKey: key,
                model: model,
                isEnabled: enabled,
                maxPasses: maxPasses,
                maxCandidates: maxCandidates,
                maxBatches: maxBatches,
                maxDossierTokens: maxDossierTokens
            )
        }

        return nil
    }
}
