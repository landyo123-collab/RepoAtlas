import Foundation

struct ContextSlice: Codable, Hashable {
    let filePath: String
    let lineRange: String
    let reason: String
    let tokenEstimate: Int
    let contentHash: String
    let text: String
}

struct AIContext: Codable {
    let prompt: String
    let slices: [ContextSlice]
    let tokenEstimate: Int
    let cacheKey: String
}

struct AnswerCacheEntry: Codable {
    let query: String
    let answer: String
    let repoHash: String
    let contextKey: String
    let createdAt: Date
}

struct ContextCacheEntry: Codable {
    let repoHash: String
    let contextKey: String
    let createdAt: Date
    let slices: [ContextSlice]
    let tokenEstimate: Int
}
