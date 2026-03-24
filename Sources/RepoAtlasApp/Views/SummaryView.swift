import SwiftUI

struct SummaryView: View {
    @EnvironmentObject private var store: RepoStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Atlas Summary")
                .font(.title3.bold())

            if let summary = store.repo?.summary {
                Text(summary.offlineNarrative)
                    .foregroundStyle(.secondary)

                GroupBox("Top Files") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(summary.topFiles.prefix(6)) { file in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.relativePath)
                                        .font(.subheadline.weight(.semibold))
                                    Text(file.matchingSignals.joined(separator: ", ").isEmpty ? file.detectedLanguage : file.matchingSignals.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.1f", file.importanceScore))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Architectural Zones") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(summary.zones.prefix(6)) { zone in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(zone.title)
                                    .font(.subheadline.weight(.semibold))
                                Text("\(zone.fileCount) files • \(zone.dominantExtensions.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Languages") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.languageCounts.sorted(by: { $0.value > $1.value }), id: \.key) { pair in
                            HStack {
                                Text(pair.key)
                                Spacer()
                                Text("\(pair.value)")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            } else {
                Text("Load a repository to see the atlas summary.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
