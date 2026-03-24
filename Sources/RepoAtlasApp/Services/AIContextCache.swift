import Foundation

struct AIContextCache {
    private let fileManager = FileManager.default

    func cachedAnswer(repoHash: String, contextKey: String, query: String) -> AnswerCacheEntry? {
        let url = answersDirectory().appendingPathComponent(cacheFilename(repoHash: repoHash, contextKey: contextKey, query: query))
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AnswerCacheEntry.self, from: data)
    }

    func store(answer: AnswerCacheEntry) {
        let url = answersDirectory().appendingPathComponent(cacheFilename(repoHash: answer.repoHash, contextKey: answer.contextKey, query: answer.query))
        try? fileManager.createDirectory(at: answersDirectory(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.pretty.encode(answer) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func store(context: ContextCacheEntry) {
        let url = contextsDirectory().appendingPathComponent("\(context.contextKey).json")
        try? fileManager.createDirectory(at: contextsDirectory(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.pretty.encode(context) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func cacheFilename(repoHash: String, contextKey: String, query: String) -> String {
        (repoHash + "|" + contextKey + "|" + query).sha256Hex + ".json"
    }

    private func baseDirectory() -> URL {
        let appSupport = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RepoAtlas/Cache")
        try? fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    private func answersDirectory() -> URL {
        baseDirectory().appendingPathComponent("answers")
    }

    private func contextsDirectory() -> URL {
        baseDirectory().appendingPathComponent("contexts")
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
