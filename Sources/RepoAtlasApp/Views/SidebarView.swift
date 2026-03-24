import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: RepoStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            if let repo = store.repo {
                FileTreeView(nodes: store.fileTree, selection: $store.selectedFilePath)
                    .overlay(alignment: .bottomLeading) {
                        Text(store.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }

                footer(repo: repo)
            } else {
                EmptySidebarStateView()
            }
        }
        .padding(14)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.repo?.displayName ?? "Repo Atlas")
                .font(.title3.bold())

            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func footer(repo: RepoModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label("\(repo.summary.scannedTextFiles) text files", systemImage: "doc.text")
                .font(.caption)
            Label("\(repo.summary.zones.count) inferred zones", systemImage: "square.grid.3x3")
                .font(.caption)
            Label("\(repo.summary.languageCounts.count) languages", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.caption)

            // Repo memory status
            Divider()
            if store.isIndexingMemory {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Building repo memory...")
                        .font(.caption2)
                }
                if !store.memoryIndexProgress.isEmpty {
                    Text(store.memoryIndexProgress)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if store.repoMemoryIndexed {
                Label("\(store.repoMemoryFileCount) files in repo memory", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.green)
                if let indexedAt = store.repoMemoryIndexedAt {
                    Text("Indexed \(indexedAt, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if store.embeddingCount > 0 {
                    Label("\(store.embeddingCount) embeddings", systemImage: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                } else if store.embeddingsAvailable {
                    Label("Embeddings available (rescan to build)", systemImage: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if store.repoMemoryStale {
                    Label("Index stale - rescan recommended", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Label("No repo memory", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
    }
}

private struct EmptySidebarStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()

            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)

            Text("No Repository Loaded")
                .font(.headline)

            Text("Open a local codebase to build its atlas.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
