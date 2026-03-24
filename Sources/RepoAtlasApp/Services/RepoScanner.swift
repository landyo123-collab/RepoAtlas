import Foundation

struct RepoScanResult {
    let rootURL: URL
    let files: [ScannedFile]
    let skippedFiles: Int
    let repoHash: String
}

struct ScannedFile {
    let relativePath: String
    let absolutePath: String
    let displayName: String
    let fileExtension: String
    let sizeBytes: Int
    let depth: Int
    let snippet: String
    let fullPreview: String
    let contentHash: String
    let rawText: String
    let lineCount: Int
    let topLevelDirectory: String
    let isWhitelisted: Bool
    let detectedLanguage: String
}

struct RepoScanner {
    func scan(rootURL: URL) throws -> RepoScanResult {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            throw NSError(domain: "RepoAtlas", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to enumerate repository."])
        }

        var results: [ScannedFile] = []
        var skipped = 0

        while let fileURL = enumerator.nextObject() as? URL {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey])

            if resourceValues.isDirectory == true {
                if AppConstants.ignoredDirectories.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard resourceValues.isRegularFile == true else {
                skipped += 1
                continue
            }

            let size = resourceValues.fileSize ?? 0
            if size > AppConstants.maxFileSizeBytes {
                skipped += 1
                continue
            }

            let filename = fileURL.lastPathComponent
            let fileExtension = fileURL.pathExtension.lowercased()
            let isWhitelisted = AppConstants.specialFilenames.contains(filename)
            let isAllowed = isWhitelisted || AppConstants.allowedExtensions.contains(fileExtension)
            if !isAllowed {
                skipped += 1
                continue
            }

            let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            guard let data = try? Data(contentsOf: fileURL) else {
                skipped += 1
                continue
            }

            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let preview = text.firstLines(AppConstants.previewLineLimit)
            let snippet = text.firstLines(AppConstants.snippetLineLimit)
            let lineCount = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).count
            let hashInput = relativePath + "::" + text
            let contentHash = hashInput.sha256Hex
            let pathParts = relativePath.split(separator: "/").map(String.init)
            let depth = max(0, pathParts.count - 1)
            let topLevelDirectory = pathParts.first ?? "/"
            let language = Self.languageLabel(forExtension: fileExtension, filename: filename)

            results.append(
                ScannedFile(
                    relativePath: relativePath,
                    absolutePath: fileURL.path,
                    displayName: filename,
                    fileExtension: fileExtension,
                    sizeBytes: size,
                    depth: depth,
                    snippet: snippet,
                    fullPreview: preview,
                    contentHash: contentHash,
                    rawText: text,
                    lineCount: lineCount,
                    topLevelDirectory: topLevelDirectory,
                    isWhitelisted: isWhitelisted,
                    detectedLanguage: language
                )
            )
        }

        let ordered = results.sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
        let repoHash = ordered.map { "\($0.relativePath):\($0.contentHash)" }.joined(separator: "|").sha256Hex

        return RepoScanResult(rootURL: rootURL, files: ordered, skippedFiles: skipped, repoHash: repoHash)
    }

    private static func languageLabel(forExtension fileExtension: String, filename: String) -> String {
        switch fileExtension {
        case "swift": return "Swift"
        case "py": return "Python"
        case "js", "jsx": return "JavaScript"
        case "ts", "tsx": return "TypeScript"
        case "json": return "JSON"
        case "md": return "Markdown"
        case "yaml", "yml": return "YAML"
        case "toml": return "TOML"
        case "rb": return "Ruby"
        case "go": return "Go"
        case "rs": return "Rust"
        case "java": return "Java"
        case "kt", "kts": return "Kotlin"
        case "html": return "HTML"
        case "css", "scss": return "CSS"
        case "sql": return "SQL"
        case "sh", "zsh", "bash": return "Shell"
        case "plist": return "Property List"
        case "xml": return "XML"
        case "env": return "Environment"
        default:
            if filename == "Dockerfile" { return "Docker" }
            if filename == "Makefile" { return "Make" }
            return fileExtension.isEmpty ? "Plain Text" : fileExtension.uppercased()
        }
    }
}
