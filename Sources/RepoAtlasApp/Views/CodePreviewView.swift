import SwiftUI

struct CodePreviewView: View {
    @EnvironmentObject private var store: RepoStore

    var body: some View {
        Group {
            if let file = store.selectedFile() {
                VStack(alignment: .leading, spacing: 12) {
                    metadataHeader(for: file)
                    Divider()
                    ScrollView {
                        Text(file.fullPreview.isEmpty ? file.snippet : file.fullPreview)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 24)
                    }
                }
                .padding(18)
            } else {
                EmptyCodePreviewStateView()
            }
        }
    }

    private func metadataHeader(for file: RepoFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(file.relativePath)
                .font(.headline)

            HStack(spacing: 10) {
                MetaChip(label: file.detectedLanguage)
                MetaChip(label: "Score \(String(format: "%.1f", file.importanceScore))")
                MetaChip(label: "\(file.importCount) imports")
                MetaChip(label: "\(file.lineCount) lines")
            }

            if !file.matchingSignals.isEmpty {
                HStack(spacing: 8) {
                    ForEach(file.matchingSignals, id: \.self) { signal in
                        MetaChip(label: signal)
                    }
                }
            }
        }
    }
}

private struct EmptyCodePreviewStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)

            Text("No File Selected")
                .font(.headline)

            Text("Choose a file from the atlas to inspect its preview.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MetaChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}
