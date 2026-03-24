import Foundation

struct RepoRunContextBuilder {
    private let runKeywords = [
        "run", "start", "dev", "serve", "launch", "build", "localhost",
        "port", "xcodebuild", "swift run", "npm", "pnpm", "yarn", "python", "cargo run"
    ]

    private let preferredNames: Set<String> = [
        "README", "README.md", "Package.swift", "package.json", "pyproject.toml",
        "requirements.txt", "Cargo.toml", "Makefile", "docker-compose.yml",
        "Podfile", "Gemfile", "build.gradle", "build.gradle.kts", "Procfile",
        ".env.example", ".env"
    ]

    func buildContext(repo: RepoModel) -> RepoRunContext {
        let rootURL = URL(fileURLWithPath: repo.rootPath)
        let containers = discoverProjectContainers(in: rootURL)
        let selectedFiles = selectFiles(from: repo)
        let fileBlocks = selectedFiles.map { file in
            let maxLines = file.displayName.lowercased().contains("readme") ? 180 : 120
            let snippet = file.fullPreview.firstLines(maxLines)
            return """
            FILE: \(file.relativePath)
            ---
            \(snippet)
            """
        }.joined(separator: "\n\n")

        let topFilePaths = repo.summary.topFiles.prefix(10).map(\.relativePath).joined(separator: ", ")
        let containerBlock = containers.isEmpty ? "(none found)" : containers.joined(separator: "\n")

        let prompt = """
        You are Repo Atlas Launchpad. Your job is to produce one realistic run plan for this local repository.

        OUTPUT RULES:
        - Return JSON only. No markdown. No commentary.
        - Follow this exact schema:
          {
            "projectType": "string",
            "command": "string",
            "args": ["string"],
            "workingDirectory": "string",
            "outputMode": "webPreview|nativeApp|terminal",
            "port": 3000 or null,
            "confidence": 0.0-1.0,
            "reason": "string",
            "launchNotes": "string or null",
            "isRunnable": true or false,
            "blocker": "string or null",
            "appBundlePath": "string or null"
          }

        SAFETY AND HONESTY:
        - Provide exactly one plan.
        - Do not suggest destructive commands.
        - Do not suggest package installation commands.
        - If the repo cannot be confidently run, set "isRunnable": false and explain blocker.
        - Keep command deterministic and practical for local run.
        - Use workingDirectory relative to repo root whenever possible.
        - If outputMode is webPreview, provide a likely localhost port when available.
        - If outputMode is nativeApp, provide appBundlePath. If you cannot provide a reliable .app path, set isRunnable to false and explain blocker.

        REPO:
        - Name: \(repo.displayName)
        - Root: \(repo.rootPath)
        - Languages: \(repo.summary.languageCounts.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        - Top files: \(topFilePaths)
        - Project containers:
        \(containerBlock)

        CONTEXT FILES:
        \(fileBlocks)
        """

        return RepoRunContext(prompt: prompt, includedFiles: selectedFiles.map(\.relativePath))
    }

    private func selectFiles(from repo: RepoModel) -> [RepoFile] {
        var ordered: [RepoFile] = []
        var seen = Set<String>()

        func append(_ file: RepoFile) {
            guard !seen.contains(file.relativePath) else { return }
            ordered.append(file)
            seen.insert(file.relativePath)
        }

        let mustHave = repo.files.filter { preferredNames.contains($0.displayName) }
        for file in mustHave.sorted(by: { $0.relativePath < $1.relativePath }) {
            append(file)
        }

        let readmeMatches = repo.files.filter {
            $0.displayName.lowercased().contains("readme") || $0.relativePath.lowercased().contains("readme")
        }
        for file in readmeMatches {
            append(file)
        }

        for file in repo.summary.topFiles.prefix(8) {
            append(file)
        }

        let keywordMatches = repo.files.filter { file in
            let haystack = (file.relativePath + "\n" + file.snippet).lowercased()
            return runKeywords.contains(where: { haystack.contains($0) })
        }
        for file in keywordMatches.prefix(10) {
            append(file)
        }

        return Array(ordered.prefix(18))
    }

    private func discoverProjectContainers(in rootURL: URL) -> [String] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return []
        }

        var hits: [String] = []
        while let item = enumerator.nextObject() as? URL {
            let last = item.lastPathComponent
            if AppConstants.ignoredDirectories.contains(last) {
                enumerator.skipDescendants()
                continue
            }
            if last.hasSuffix(".xcodeproj") || last.hasSuffix(".xcworkspace") {
                let path = item.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                hits.append(path)
            }
            if hits.count >= 20 {
                break
            }
        }
        return hits.sorted()
    }
}
