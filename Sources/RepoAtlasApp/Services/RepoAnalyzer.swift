import Foundation

struct RepoAnalyzer {
    func analyze(scan: RepoScanResult) -> RepoModel {
        let analyzedFiles = scan.files.map(analyzeFile)
        let sortedTopFiles = analyzedFiles.sorted { lhs, rhs in
            if lhs.importanceScore == rhs.importanceScore {
                return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
            }
            return lhs.importanceScore > rhs.importanceScore
        }

        let zones = inferZones(from: analyzedFiles)
        let languageCounts = Dictionary(grouping: analyzedFiles, by: \.detectedLanguage)
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
            .reduce(into: [String: Int]()) { $0[$1.key] = $1.value }

        let summary = RepoSummary(
            totalFiles: scan.files.count + scan.skippedFiles,
            scannedTextFiles: analyzedFiles.count,
            skippedFiles: scan.skippedFiles,
            languageCounts: languageCounts,
            topFiles: Array(sortedTopFiles.prefix(8)),
            zones: zones,
            offlineNarrative: narrative(for: analyzedFiles, zones: zones, languages: languageCounts)
        )

        return RepoModel(
            rootPath: scan.rootURL.path,
            displayName: scan.rootURL.lastPathComponent,
            files: analyzedFiles,
            edges: buildEdges(from: scan.files),
            summary: summary,
            repoHash: scan.repoHash,
            analyzedAt: Date()
        )
    }

    private func analyzeFile(_ file: ScannedFile) -> RepoFile {
        let lowercaseName = file.displayName.lowercased()
        var signals: [String] = []
        var patternScore = 0.0

        for (pattern, weight) in AppConstants.filenameWeights {
            if lowercaseName.contains(pattern.lowercased()) || file.relativePath.lowercased().contains(pattern.lowercased()) {
                patternScore += weight
                signals.append(pattern)
            }
        }

        if file.isWhitelisted {
            patternScore += 1.8
            signals.append("whitelist")
        }

        if file.rawText.contains("@ATLAS:IMPORTANT") || file.rawText.contains("ATLAS:IMPORTANT") {
            patternScore += 4.0
            signals.append("atlas-marker")
        }

        let importCount = estimateImportCount(in: file.rawText)
        let importScore = min(3.2, Double(importCount) / 5.0)
        let depthScore = max(0.4, 2.6 - (Double(file.depth) * 0.35))
        let structureBonus = structuralBonus(path: file.relativePath)
        let total = ((patternScore * 0.5) + importScore + depthScore + structureBonus)

        return RepoFile(
            relativePath: file.relativePath,
            absolutePath: file.absolutePath,
            displayName: file.displayName,
            fileExtension: file.fileExtension,
            sizeBytes: file.sizeBytes,
            depth: file.depth,
            snippet: file.snippet,
            fullPreview: file.fullPreview,
            contentHash: file.contentHash,
            importCount: importCount,
            importanceScore: (total * 10).rounded() / 10,
            matchingSignals: Array(Set(signals)).sorted(),
            topLevelDirectory: file.topLevelDirectory,
            isWhitelisted: file.isWhitelisted,
            lineCount: file.lineCount,
            detectedLanguage: file.detectedLanguage
        )
    }

    private func estimateImportCount(in text: String) -> Int {
        let patterns = [
            #"(?m)^\s*import\s+[A-Za-z0-9_\.]+"#,
            #"(?m)^\s*from\s+[A-Za-z0-9_\.]+\s+import\s+"#,
            #"(?m)^\s*#include\s+[<\"][^>\"]+[>\"]"#,
            #"(?m)require\("#,
            #"(?m)^\s*use\s+[A-Za-z0-9_\\]+"#
        ]

        return patterns.reduce(0) { partial, pattern in
            partial + text.matches(for: pattern).count
        }
    }

    private func structuralBonus(path: String) -> Double {
        let lower = path.lowercased()
        if lower.contains("/views/") || lower.contains("/ui/") { return 1.2 }
        if lower.contains("/services/") || lower.contains("/network/") { return 1.4 }
        if lower.contains("/models/") { return 0.9 }
        if lower.contains("/tests/") { return 0.4 }
        return 0.7
    }

    private func inferZones(from files: [RepoFile]) -> [RepoZone] {
        let groups = Dictionary(grouping: files) { file in
            file.topLevelDirectory == "/" ? "Root" : file.topLevelDirectory
        }

        var zones: [RepoZone] = []
        for (title, groupFiles) in groups {
            let groupedExtensions = Dictionary(grouping: groupFiles, by: \.fileExtension)
            let extensionCounts = groupedExtensions.mapValues(\.count)
            let dominantExtensions = extensionCounts
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value { return lhs.key < rhs.key }
                    return lhs.value > rhs.value
                }
                .prefix(3)
                .map { $0.key.isEmpty ? "(none)" : $0.key }

            let totalImportance = groupFiles.map(\.importanceScore).reduce(0, +)
            let average = totalImportance / Double(max(groupFiles.count, 1))
            zones.append(
                RepoZone(
                    title: title,
                    fileCount: groupFiles.count,
                    dominantExtensions: dominantExtensions,
                    averageImportance: (average * 10).rounded() / 10
                )
            )
        }

        return zones.sorted { lhs, rhs in
            if lhs.averageImportance == rhs.averageImportance {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.averageImportance > rhs.averageImportance
        }
    }

    private func narrative(for files: [RepoFile], zones: [RepoZone], languages: [String: Int]) -> String {
        let topFileNames = files.sorted { $0.importanceScore > $1.importanceScore }.prefix(3).map(\.displayName).joined(separator: ", ")
        let topZoneNames = zones.prefix(3).map(\.title).joined(separator: ", ")
        let languageSummary = languages.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) (\($0.value))" }.joined(separator: ", ")

        return "Repo Atlas found \(files.count) text files. Highest-signal files: \(topFileNames.isEmpty ? "n/a" : topFileNames). Dominant zones: \(topZoneNames.isEmpty ? "n/a" : topZoneNames). Language mix: \(languageSummary.isEmpty ? "n/a" : languageSummary)."
    }

    private func buildEdges(from files: [ScannedFile]) -> [RepoEdge] {
        files.flatMap { file in
            let patterns = [
                #"(?m)^\s*import\s+([A-Za-z0-9_\.]+)"#,
                #"(?m)^\s*from\s+([A-Za-z0-9_\.]+)\s+import\s+"#
            ]

            return patterns.flatMap { pattern in
                file.rawText.captureGroups(for: pattern).enumerated().map { index, capture in
                    RepoEdge(
                        id: "\(file.relativePath)-\(pattern)-\(index)-\(capture)",
                        sourcePath: file.relativePath,
                        targetLabel: capture,
                        kind: "import"
                    )
                }
            }
        }
    }
}

private extension String {
    func matches(for pattern: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(startIndex..., in: self)
        return regex.matches(in: self, range: range)
    }

    func captureGroups(for pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(startIndex..., in: self)
        return regex.matches(in: self, range: range).compactMap { result in
            guard result.numberOfRanges > 1, let captureRange = Range(result.range(at: 1), in: self) else { return nil }
            return String(self[captureRange])
        }
    }
}
