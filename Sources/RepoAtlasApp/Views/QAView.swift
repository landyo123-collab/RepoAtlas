import SwiftUI
import AppKit

struct QAView: View {
    @EnvironmentObject private var store: RepoStore
    @EnvironmentObject private var configManager: DeepSeekConfigManager
    let configuration: DeepSeekConfiguration
    @State private var query = "How is this repo structured?"
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DeepSeek Q&A")
                    .font(.title3.bold())
                Spacer()
                if configManager.evidenceBuilderConfiguration.isAvailable {
                    Text("EB: \(configManager.evidenceBuilderConfiguration.model)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .padding(.trailing, 4)
                }
                Text(configuration.isConfigured ? configuration.model : "Not configured")
                    .font(.caption)
                    .foregroundStyle(configuration.isConfigured ? Color.secondary : Color.orange)
            }

            MultilineQueryInput(
                text: $query,
                placeholder: "Ask a targeted question about this repo",
                isFocused: $isQueryFocused
            )

            HStack {
                Button("Ask") {
                    store.ask(query,
                              configuration: configuration,
                              embeddingConfig: configManager.embeddingConfiguration,
                              evidenceBuilderConfig: configManager.evidenceBuilderConfiguration)
                }
                .disabled(store.repo == nil || store.isAsking)

                Button("Summarize Repo") {
                    store.summarizeRepository(configuration: configuration,
                                               embeddingConfig: configManager.embeddingConfiguration,
                                               evidenceBuilderConfig: configManager.evidenceBuilderConfiguration)
                }
                .disabled(store.repo == nil || store.isAsking)
            }

            if store.isAsking {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView("Asking DeepSeek…")
                        .controlSize(.small)
                    if store.evidenceBuilderActive, !store.evidenceBuilderProgress.isEmpty {
                        Text(store.evidenceBuilderProgress)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            GroupBox("Answer") {
                ScrollView {
                    Text(
                        store.latestAnswer.isEmpty
                        ? "Ask a question to get a bounded, repo-aware answer. If DeepSeek is unavailable, Repo Atlas will try to reuse a cached answer for the same repo hash and context key."
                        : store.latestAnswer
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(minHeight: 160)
            }

            if !store.latestContextSlices.isEmpty {
                GroupBox("Context Preview") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !store.retrievalDebugSummary.isEmpty {
                            Text(store.retrievalDebugSummary)
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .padding(.bottom, 2)
                        }
                        ForEach(store.latestContextSlices.prefix(8), id: \.self) { slice in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slice.filePath)
                                    .font(.caption.weight(.semibold))
                                Text("\(slice.lineRange) • \(slice.reason) • ~\(slice.tokenEstimate) tokens")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if store.latestContextSlices.count > 8 {
                            Text("+\(store.latestContextSlices.count - 8) more segments")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Evidence Builder Diagnostics (shown when dossier was used)
            if !store.evidenceBuilderDiagnostics.isEmpty {
                GroupBox("Evidence Builder") {
                    ScrollView {
                        Text(store.evidenceBuilderDiagnostics)
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
    }
}

// `TextField(axis: .vertical)` has had focus/editing regressions on some older macOS versions,
// especially when embedded in other scrolling containers. `TextEditor` is the most reliable
// multi-line input on macOS across older SwiftUI runtimes.
private struct MultilineQueryInput: View {
    @Binding var text: String
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .focused(isFocused)
                .font(.body)
                .padding(8)
                .frame(minHeight: 72, maxHeight: 120)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
                .cornerRadius(6)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                    .padding(.top, 14)
                    .onTapGesture { isFocused.wrappedValue = true }
            }
        }
        .accessibilityLabel(Text(placeholder))
    }
}
