import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var configManager: DeepSeekConfigManager
    @State private var apiKey = ""
    @State private var baseURL = "https://api.deepseek.com"
    @State private var model = "deepseek-chat"
    @State private var savedBanner = false

    @State private var openaiKey = ""
    @State private var embeddingModel = "text-embedding-3-small"
    @State private var embeddingsEnabled = false
    @State private var savedEmbeddingBanner = false

    @State private var ebEnabled = false
    @State private var ebModel = EvidenceBuilderConfiguration.defaultModel
    @State private var ebMaxPasses = 3
    @State private var ebMaxCandidates = 1500
    @State private var ebMaxBatches = 12
    @State private var ebMaxDossierTokens = 24_000
    @State private var savedEBBanner = false

    var body: some View {
        Form {
            Section("DeepSeek (Reasoning)") {
                SecureField("API Key", text: $apiKey)
                TextField("Base URL", text: $baseURL)
                TextField("Model", text: $model)
            }

            Section {
                HStack {
                    Button("Save") {
                        configManager.save(apiKey: apiKey, baseURL: baseURL, model: model)
                        savedBanner = true
                    }
                    Button("Reload From Disk") {
                        configManager.reload()
                        loadCurrentValues()
                    }
                    Spacer()
                    if savedBanner {
                        Text("Saved")
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("OpenAI Embeddings") {
                Toggle("Enable Embeddings", isOn: $embeddingsEnabled)
                SecureField("OpenAI API Key", text: $openaiKey)
                TextField("Embedding Model", text: $embeddingModel)

                Text("Embeddings improve retrieval accuracy by matching semantic meaning. When disabled, Repo Atlas still works using lexical + structural retrieval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Save Embedding Settings") {
                        configManager.saveEmbedding(apiKey: openaiKey, model: embeddingModel, enabled: embeddingsEnabled)
                        savedEmbeddingBanner = true
                    }
                    Spacer()
                    if savedEmbeddingBanner {
                        Text("Saved")
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("Evidence Builder (OpenAI)") {
                Toggle("Enable Evidence Builder", isOn: $ebEnabled)

                TextField("Model", text: $ebModel)
                    .help("OpenAI model for evidence building. Default: \(EvidenceBuilderConfiguration.defaultModel)")

                HStack {
                    Text("Max Passes")
                    TextField("", value: $ebMaxPasses, format: .number)
                        .frame(width: 60)
                }
                HStack {
                    Text("Max Candidates")
                    TextField("", value: $ebMaxCandidates, format: .number)
                        .frame(width: 80)
                }
                HStack {
                    Text("Max Batches")
                    TextField("", value: $ebMaxBatches, format: .number)
                        .frame(width: 60)
                }
                HStack {
                    Text("Max Dossier Tokens")
                    TextField("", value: $ebMaxDossierTokens, format: .number)
                        .frame(width: 80)
                }

                Text("The Evidence Builder uses OpenAI to discover, expand, and compress repository evidence into a structured dossier before DeepSeek answers. Uses the same OpenAI API key as embeddings. Requires repo memory to be indexed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Save Evidence Builder Settings") {
                        configManager.saveEvidenceBuilder(
                            enabled: ebEnabled,
                            model: ebModel,
                            maxPasses: ebMaxPasses,
                            maxCandidates: ebMaxCandidates,
                            maxBatches: ebMaxBatches,
                            maxDossierTokens: ebMaxDossierTokens
                        )
                        savedEBBanner = true
                    }
                    Spacer()
                    if savedEBBanner {
                        Text("Saved")
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("Config paths") {
                Text("You can also put credentials in ~/.repoatlas.env using the included .env.example file.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onAppear(perform: loadCurrentValues)
    }

    private func loadCurrentValues() {
        let configuration = configManager.configuration
        apiKey = configuration.apiKey
        baseURL = configuration.baseURL
        model = configuration.model
        savedBanner = false

        let embConfig = configManager.embeddingConfiguration
        openaiKey = embConfig.apiKey
        embeddingModel = embConfig.model
        embeddingsEnabled = embConfig.isEnabled
        savedEmbeddingBanner = false

        let ebConfig = configManager.evidenceBuilderConfiguration
        ebEnabled = ebConfig.isEnabled
        ebModel = ebConfig.model
        ebMaxPasses = ebConfig.maxPasses
        ebMaxCandidates = ebConfig.maxCandidates
        ebMaxBatches = ebConfig.maxBatches
        ebMaxDossierTokens = ebConfig.maxDossierTokens
        savedEBBanner = false
    }
}
