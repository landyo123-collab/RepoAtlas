import Foundation

struct MemoryBuildProgress {
    let phase: String
    let detail: String
    let filesDone: Int
    let filesTotal: Int
    var fraction: Double {
        guard filesTotal > 0 else { return 0 }
        return Double(filesDone) / Double(filesTotal)
    }
}

struct RepoMemoryBuilder {
    private let classifier = FileClassifier()
    private let segmenter = FileSegmenter()
    private let symbolExtractor = SymbolExtractor()

    /// Build the full persistent repo memory from a scan result and analyzed model.
    /// This is designed to run on a background thread.
    /// If embeddingConfig is provided, eagerly embeds file summaries.
    func buildMemory(from scan: RepoScanResult, repo: RepoModel,
                     embeddingConfig: EmbeddingConfiguration = .disabled,
                     progress: @escaping (MemoryBuildProgress) -> Void) throws {
        let startTime = CFAbsoluteTimeGetCurrent()

        let store = try RepoMemoryStore(repoRoot: repo.rootPath)

        // Clear previous index for this repo
        try store.clearAll()

        let allPaths = scan.files.map(\.relativePath)
        let fileCount = scan.files.count

        // Detect project roots from manifest files
        let projectRoots = detectProjectRoots(files: scan.files)

        // Phase 1: Insert all files with classification + tier + project root
        progress(MemoryBuildProgress(phase: "Indexing files", detail: "Classifying \(fileCount) files...", filesDone: 0, filesTotal: fileCount))

        var fileIdMap: [String: Int64] = [:]  // relativePath -> file ID
        var fileTierMap: [String: CorpusTier] = [:]  // relativePath -> tier (for phase 2 skip check)

        try store.inTransaction {
            for (i, scannedFile) in scan.files.enumerated() {
                let classification = classifier.classify(
                    relativePath: scannedFile.relativePath,
                    name: scannedFile.displayName,
                    ext: scannedFile.fileExtension,
                    language: scannedFile.detectedLanguage
                )

                let tier = classifier.classifyTier(relativePath: scannedFile.relativePath)
                let projRoot = nearestProjectRoot(forPath: scannedFile.relativePath, projectRoots: projectRoots)

                fileTierMap[scannedFile.relativePath] = tier

                // Get importance score from analyzed repo model
                let repoFile = repo.files.first { $0.relativePath == scannedFile.relativePath }
                let importance = repoFile?.importanceScore ?? 0

                // Generate lightweight summary
                let summary = generateFileSummary(scannedFile: scannedFile, classification: classification)

                let modDate: Double
                if let attrs = try? FileManager.default.attributesOfItem(atPath: scannedFile.absolutePath),
                   let date = attrs[.modificationDate] as? Date {
                    modDate = date.timeIntervalSince1970
                } else {
                    modDate = Date().timeIntervalSince1970
                }

                let fileId = try store.insertFile(
                    relativePath: scannedFile.relativePath,
                    name: scannedFile.displayName,
                    ext: scannedFile.fileExtension,
                    fileType: classification.fileType.rawValue,
                    roleTags: classification.roleTags,
                    language: scannedFile.detectedLanguage,
                    sizeBytes: scannedFile.sizeBytes,
                    lineCount: scannedFile.lineCount,
                    modifiedAt: modDate,
                    contentHash: scannedFile.contentHash,
                    importanceScore: importance,
                    depth: scannedFile.depth,
                    isIndexed: true,
                    summary: summary,
                    corpusTier: tier.rawValue,
                    projectRoot: projRoot
                )
                fileIdMap[scannedFile.relativePath] = fileId

                if i % 100 == 0 {
                    progress(MemoryBuildProgress(phase: "Indexing files", detail: scannedFile.relativePath, filesDone: i, filesTotal: fileCount))
                }
            }
        }

        // Phase 2: Segment files and extract symbols (skip external/generated/binary)
        progress(MemoryBuildProgress(phase: "Segmenting", detail: "Building segments and symbols...", filesDone: 0, filesTotal: fileCount))

        try store.inTransaction {
            for (i, scannedFile) in scan.files.enumerated() {
                guard let fileId = fileIdMap[scannedFile.relativePath] else { continue }

                // Skip segmentation/symbols for non-first-party tiers — they bloat the index
                let tier = fileTierMap[scannedFile.relativePath] ?? .firstParty
                if tier == .externalDependency || tier == .generatedArtifact || tier == .binaryOrIgnored {
                    if i % 200 == 0 {
                        progress(MemoryBuildProgress(phase: "Segmenting", detail: "Skipping \(tier.rawValue): \(scannedFile.relativePath)", filesDone: i, filesTotal: fileCount))
                    }
                    continue
                }

                // Segment the file
                let segments = segmenter.segment(
                    text: scannedFile.rawText,
                    language: scannedFile.detectedLanguage,
                    fileName: scannedFile.displayName
                )

                for seg in segments {
                    try store.insertSegment(
                        fileId: fileId,
                        segmentIndex: seg.index,
                        startLine: seg.startLine,
                        endLine: seg.endLine,
                        tokenEstimate: seg.tokenEstimate,
                        segmentType: seg.segmentType,
                        label: seg.label,
                        content: seg.content,
                        filePath: scannedFile.relativePath
                    )
                }

                // Extract symbols
                let symbols = symbolExtractor.extractSymbols(from: scannedFile.rawText, language: scannedFile.detectedLanguage)
                for sym in symbols {
                    try store.insertSymbol(
                        fileId: fileId,
                        name: sym.name,
                        kind: sym.kind,
                        lineNumber: sym.lineNumber,
                        signature: sym.signature,
                        container: sym.container,
                        filePath: scannedFile.relativePath
                    )
                }

                // Extract references
                let refs = symbolExtractor.extractReferences(from: scannedFile.rawText, language: scannedFile.detectedLanguage, allFilePaths: allPaths)
                for ref in refs {
                    try store.insertReference(
                        sourceFileId: fileId,
                        targetPath: ref.resolvedPath,
                        targetSymbol: ref.targetSymbol,
                        kind: ref.kind,
                        lineNumber: ref.lineNumber
                    )
                }

                if i % 50 == 0 {
                    progress(MemoryBuildProgress(phase: "Segmenting", detail: scannedFile.relativePath, filesDone: i, filesTotal: fileCount))
                }
            }
        }

        // Phase 3: Directory summaries
        progress(MemoryBuildProgress(phase: "Summarizing", detail: "Building directory summaries...", filesDone: fileCount, filesTotal: fileCount))

        try buildDirectorySummaries(store: store, files: scan.files)

        // Phase 3b: Subtree/project summaries
        progress(MemoryBuildProgress(phase: "Summarizing", detail: "Building subtree summaries...", filesDone: fileCount, filesTotal: fileCount))

        try buildSubtreeSummaries(store: store, files: scan.files, projectRoots: projectRoots, fileTierMap: fileTierMap)

        // Phase 3c: Eager file-summary embeddings (if configured)
        if embeddingConfig.isAvailable {
            progress(MemoryBuildProgress(phase: "Embedding", detail: "Embedding file summaries...", filesDone: 0, filesTotal: fileCount))
            embedFileSummaries(store: store, fileIdMap: fileIdMap, files: scan.files,
                               fileTierMap: fileTierMap, config: embeddingConfig, progress: progress)
        }

        // Phase 4: Build repo passport and meta
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        let manifests = scan.files.filter { file in
            let lower = file.displayName.lowercased()
            let manifestNames: Set<String> = ["package.json", "package.swift", "cargo.toml", "gemfile",
                                               "pyproject.toml", "requirements.txt", "build.gradle",
                                               "podfile", "go.mod", "composer.json", "setup.py"]
            return manifestNames.contains(lower)
        }.map(\.relativePath)

        let topDirs = Array(Set(scan.files.map(\.topLevelDirectory))).sorted()

        let runtimeShape = inferRuntimeShape(repo: repo, manifests: manifests)
        let passport = buildPassport(repo: repo, manifests: manifests, topDirs: topDirs, runtimeShape: runtimeShape, indexedCount: fileCount)

        let meta = RepoMeta(
            rootPath: repo.rootPath,
            displayName: repo.displayName,
            repoHash: repo.repoHash,
            fileCount: fileCount,
            indexedFileCount: fileCount,
            languageMix: repo.summary.languageCounts,
            manifestList: manifests,
            topLevelDirs: topDirs,
            runtimeShape: runtimeShape,
            passport: passport,
            indexedAt: Date(),
            scanDurationMs: elapsed,
            indexVersion: 1
        )

        try store.upsertRepoMeta(meta)

        // Initialize session state
        try store.saveSession(StoredSessionState(
            recentQueries: [], recentFiles: [],
            activeTopic: "", activeSubsystem: "",
            updatedAt: Date()
        ))

        progress(MemoryBuildProgress(phase: "Complete", detail: "Indexed \(fileCount) files in \(elapsed)ms", filesDone: fileCount, filesTotal: fileCount))
    }

    // MARK: - Directory summaries

    private func buildDirectorySummaries(store: RepoMemoryStore, files: [ScannedFile]) throws {
        // Group files by directory
        var dirFiles: [String: [ScannedFile]] = [:]
        for file in files {
            let dir = (file.relativePath as NSString).deletingLastPathComponent
            let key = dir.isEmpty ? "." : dir
            dirFiles[key, default: []].append(file)
        }

        try store.inTransaction {
            for (dir, dirFileList) in dirFiles {
                let langCounts = Dictionary(grouping: dirFileList, by: \.detectedLanguage).mapValues(\.count)
                let dominant = langCounts.max(by: { $0.value < $1.value })?.key ?? ""
                let fileNames = dirFileList.prefix(15).map(\.displayName).joined(separator: ", ")
                let extras = dirFileList.count > 15 ? " (+\(dirFileList.count - 15) more)" : ""

                let summary = "\(dir): \(dirFileList.count) files, primarily \(dominant). Contains: \(fileNames)\(extras)"
                try store.upsertDirSummary(path: dir, summary: summary, fileCount: dirFileList.count, dominantLanguage: dominant)
            }
        }
    }

    // MARK: - File summary generation

    private func generateFileSummary(scannedFile: ScannedFile, classification: FileClassification) -> String {
        let name = scannedFile.displayName
        let lang = scannedFile.detectedLanguage
        let lines = scannedFile.lineCount
        let tags = classification.roleTags.joined(separator: ", ")

        // Extract first meaningful non-comment line as a hint
        let contentHint: String
        let textLines = scannedFile.rawText.components(separatedBy: .newlines)
        let meaningful = textLines.prefix(30).first { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("//") && !t.hasPrefix("#") && !t.hasPrefix("/*") && !t.hasPrefix("*")
        }
        if let hint = meaningful {
            contentHint = String(hint.trimmingCharacters(in: .whitespaces).prefix(80))
        } else {
            contentHint = ""
        }

        var parts = ["\(name) (\(lang), \(lines) lines)"]
        if !tags.isEmpty { parts.append("roles: \(tags)") }
        if !contentHint.isEmpty { parts.append("starts: \(contentHint)") }
        return parts.joined(separator: " | ")
    }

    // MARK: - Runtime shape inference

    private func inferRuntimeShape(repo: RepoModel, manifests: [String]) -> String {
        let manifestNames = Set(manifests.map { ($0 as NSString).lastPathComponent.lowercased() })
        let langs = repo.summary.languageCounts

        if manifestNames.contains("package.swift") || manifestNames.contains("podfile") {
            if langs.keys.contains("Swift") {
                return "macOS/iOS Swift app"
            }
        }
        if manifestNames.contains("package.json") {
            let hasTS = langs.keys.contains("TypeScript")
            let hasReactSignals = repo.files.contains { $0.relativePath.lowercased().contains("react") || $0.snippet.contains("import React") }
            if hasReactSignals { return hasTS ? "React TypeScript web app" : "React JavaScript web app" }
            return hasTS ? "Node.js TypeScript project" : "Node.js JavaScript project"
        }
        if manifestNames.contains("pyproject.toml") || manifestNames.contains("requirements.txt") || manifestNames.contains("setup.py") {
            return "Python project"
        }
        if manifestNames.contains("cargo.toml") { return "Rust project" }
        if manifestNames.contains("go.mod") { return "Go project" }
        if manifestNames.contains("gemfile") { return "Ruby project" }
        if manifestNames.contains("build.gradle") || manifestNames.contains("build.gradle.kts") {
            return langs.keys.contains("Kotlin") ? "Kotlin/Gradle project" : "Java/Gradle project"
        }

        let dominantLang = langs.max(by: { $0.value < $1.value })?.key ?? "Unknown"
        return "\(dominantLang) project"
    }

    // MARK: - Subtree summaries

    private func buildSubtreeSummaries(store: RepoMemoryStore, files: [ScannedFile],
                                        projectRoots: [String], fileTierMap: [String: CorpusTier]) throws {
        // Group files by their nearest project root
        var rootFiles: [String: [ScannedFile]] = [:]
        for file in files {
            let root = nearestProjectRoot(forPath: file.relativePath, projectRoots: projectRoots)
            rootFiles[root, default: []].append(file)
        }

        try store.inTransaction {
            for (root, subtreeFiles) in rootFiles {
                let firstPartyFiles = subtreeFiles.filter {
                    let tier = fileTierMap[$0.relativePath] ?? .firstParty
                    return tier == .firstParty || tier == .projectSupport
                }
                let langCounts = Dictionary(grouping: firstPartyFiles, by: \.detectedLanguage).mapValues(\.count)
                let dominant = langCounts.max(by: { $0.value < $1.value })?.key ?? ""
                let manifestsInSubtree = subtreeFiles.filter {
                    let lower = $0.displayName.lowercased()
                    return ["package.json", "package.swift", "cargo.toml", "pyproject.toml",
                            "requirements.txt", "build.gradle", "go.mod", "gemfile"].contains(lower)
                }.map(\.relativePath)

                let topFiles = firstPartyFiles
                    .sorted { ($0.lineCount, $0.displayName) > ($1.lineCount, $1.displayName) }
                    .prefix(8)
                    .map(\.displayName)
                    .joined(separator: ", ")

                let label = root.isEmpty ? "(repo root)" : root
                let summary = """
                \(label): \(subtreeFiles.count) files (\(firstPartyFiles.count) first-party), \
                primarily \(dominant). Key files: \(topFiles). \
                Manifests: \(manifestsInSubtree.isEmpty ? "none" : manifestsInSubtree.joined(separator: ", "))
                """

                try store.upsertSubtreeSummary(
                    root: root, summary: summary,
                    fileCount: subtreeFiles.count,
                    firstPartyCount: firstPartyFiles.count,
                    languageMix: langCounts,
                    manifestPaths: manifestsInSubtree
                )
            }
        }
    }

    // MARK: - Eager file-summary embeddings

    private func embedFileSummaries(store: RepoMemoryStore, fileIdMap: [String: Int64],
                                     files: [ScannedFile], fileTierMap: [String: CorpusTier],
                                     config: EmbeddingConfiguration,
                                     progress: @escaping (MemoryBuildProgress) -> Void) {
        let service = EmbeddingService()

        // Only embed first-party / projectSupport file summaries
        let eligibleFiles = files.filter {
            let tier = fileTierMap[$0.relativePath] ?? .firstParty
            return tier == .firstParty || tier == .projectSupport
        }

        let batchSize = 64
        let total = eligibleFiles.count
        var processed = 0

        // Process in batches using a synchronous wrapper around async
        let semaphore = DispatchSemaphore(value: 0)

        for batchStart in stride(from: 0, to: eligibleFiles.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, eligibleFiles.count)
            let batch = Array(eligibleFiles[batchStart..<batchEnd])

            let summaries = batch.compactMap { file -> (fileId: Int64, summary: String, hash: String)? in
                guard let fileId = fileIdMap[file.relativePath] else { return nil }
                let storedFile = store.file(byId: fileId)
                guard let summary = storedFile?.summary, !summary.isEmpty else { return nil }
                return (fileId, summary, summary.sha256Hex)
            }

            guard !summaries.isEmpty else {
                processed += batch.count
                continue
            }

            let texts = summaries.map(\.summary)

            Task {
                defer { semaphore.signal() }
                do {
                    let vectors = try await service.embedBatch(texts: texts, configuration: config)
                    for (i, vector) in vectors.enumerated() where i < summaries.count {
                        let item = summaries[i]
                        try? store.upsertEmbedding(
                            targetType: "file_summary",
                            targetId: item.fileId,
                            contentHash: item.hash,
                            model: vector.model,
                            vector: vector.values
                        )
                    }
                } catch {
                    // Embedding failures are non-fatal — system degrades gracefully
                }
            }
            semaphore.wait()

            processed += batch.count
            progress(MemoryBuildProgress(phase: "Embedding", detail: "Embedded \(processed)/\(total) file summaries",
                                          filesDone: processed, filesTotal: total))
        }
    }

    // MARK: - Project root detection

    /// Detect project boundaries by finding manifest files and treating each parent directory as a project root.
    private func detectProjectRoots(files: [ScannedFile]) -> [String] {
        let manifestNames: Set<String> = [
            "package.json", "package.swift", "cargo.toml", "gemfile",
            "pyproject.toml", "requirements.txt", "build.gradle", "build.gradle.kts",
            "podfile", "go.mod", "composer.json", "setup.py", "pom.xml",
            "meson.build", "cmakelists.txt"
        ]

        var roots: Set<String> = [""]  // Repo root is always a project root

        for file in files {
            let lower = file.displayName.lowercased()
            guard manifestNames.contains(lower) else { continue }

            // Skip manifests inside dependency directories (e.g. node_modules/foo/package.json)
            let tier = classifier.classifyTier(relativePath: file.relativePath)
            if tier == .externalDependency || tier == .generatedArtifact { continue }

            let dir = (file.relativePath as NSString).deletingLastPathComponent
            roots.insert(dir)
        }

        // Sort longest first so deepest match wins in lookups
        return roots.sorted { $0.count > $1.count }
    }

    /// Find the deepest project root that is an ancestor of the given path.
    private func nearestProjectRoot(forPath path: String, projectRoots: [String]) -> String {
        let lowerPath = path.lowercased()
        for root in projectRoots {
            if root.isEmpty { continue }  // Skip repo root, use as fallback
            let prefix = root.lowercased() + "/"
            if lowerPath.hasPrefix(prefix) || lowerPath == root.lowercased() {
                return root
            }
        }
        return ""  // Falls back to repo root
    }

    // MARK: - Passport

    private func buildPassport(repo: RepoModel, manifests: [String], topDirs: [String], runtimeShape: String, indexedCount: Int) -> String {
        let langSummary = repo.summary.languageCounts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")

        let zoneSummary = repo.summary.zones.prefix(6).map { zone in
            "\(zone.title) (\(zone.fileCount) files, avg score \(zone.averageImportance))"
        }.joined(separator: "; ")

        let topFileNames = repo.summary.topFiles.prefix(6).map(\.displayName).joined(separator: ", ")

        return """
        REPO: \(repo.displayName)
        ROOT: \(repo.rootPath)
        TYPE: \(runtimeShape)
        FILES: \(indexedCount) indexed, \(repo.summary.totalFiles) total
        LANGUAGES: \(langSummary)
        MANIFESTS: \(manifests.isEmpty ? "none" : manifests.joined(separator: ", "))
        TOP DIRS: \(topDirs.prefix(10).joined(separator: ", "))
        ZONES: \(zoneSummary)
        KEY FILES: \(topFileNames)
        INDEX: fresh as of \(ISO8601DateFormatter().string(from: Date()))
        """
    }
}
