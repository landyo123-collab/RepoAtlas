import Foundation

struct RepoModel: Codable {
    let rootPath: String
    let displayName: String
    let files: [RepoFile]
    let edges: [RepoEdge]
    let summary: RepoSummary
    let repoHash: String
    let analyzedAt: Date
}

struct RepoSummary: Codable {
    let totalFiles: Int
    let scannedTextFiles: Int
    let skippedFiles: Int
    let languageCounts: [String: Int]
    let topFiles: [RepoFile]
    let zones: [RepoZone]
    let offlineNarrative: String
}

struct RepoZone: Identifiable, Codable, Hashable {
    var id: String { title }
    let title: String
    let fileCount: Int
    let dominantExtensions: [String]
    let averageImportance: Double
}
