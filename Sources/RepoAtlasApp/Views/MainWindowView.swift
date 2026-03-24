import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct MainWindowView: View {
    @EnvironmentObject private var store: RepoStore
    @EnvironmentObject private var configManager: DeepSeekConfigManager
    @State private var isTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } content: {
            CodePreviewView()
                .navigationSplitViewColumnWidth(min: 420, ideal: 620)
        } detail: {
            InspectorPanelView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open") {
                    if let url = RepositoryPicker.pickFolder() {
                        store.importRepository(at: url, embeddingConfig: configManager.embeddingConfiguration)
                    }
                }

                Button("Rescan") {
                    store.rescanCurrentRepository(embeddingConfig: configManager.embeddingConfiguration)
                }
                .disabled(store.repo == nil)

                Button("Embed") {
                    store.embedCurrentRepository(embeddingConfig: configManager.embeddingConfiguration)
                }
                .disabled(store.repo == nil || !configManager.embeddingConfiguration.isAvailable || store.isIndexingMemory)

                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .overlay {
            if store.repo == nil {
                DropPlaceholderView(isTargeted: isTargeted)
                    .padding(40)
            }
        }
        .dropDestination(for: URL.self) { items, _ in
            if let folder = items.first(where: { $0.hasDirectoryPath }) {
                store.importRepository(at: folder, embeddingConfig: configManager.embeddingConfiguration)
                return true
            }
            return false
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

private struct DropPlaceholderView: View {
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 50, weight: .medium))

            Text("Drop a repository here")
                .font(.title2.bold())

            Text("Repo Atlas will scan the folder locally, rank important files, and prepare bounded DeepSeek context for repo Q&A.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(
                            isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 2, dash: [10])
                        )
                )
        )
    }
}
