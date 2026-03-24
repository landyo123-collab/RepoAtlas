import Foundation

struct RepoFile: Identifiable, Codable, Hashable {
    var id: String { relativePath }
    let relativePath: String
    let absolutePath: String
    let displayName: String
    let fileExtension: String
    let sizeBytes: Int
    let depth: Int
    let snippet: String
    let fullPreview: String
    let contentHash: String
    let importCount: Int
    let importanceScore: Double
    let matchingSignals: [String]
    let topLevelDirectory: String
    let isWhitelisted: Bool
    let lineCount: Int
    let detectedLanguage: String
}

struct RepoEdge: Identifiable, Codable, Hashable {
    let id: String
    let sourcePath: String
    let targetLabel: String
    let kind: String
}
