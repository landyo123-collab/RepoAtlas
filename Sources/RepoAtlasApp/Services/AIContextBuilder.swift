import Foundation

struct AIContextBuilder {
    func buildContext(for query: String, repo: RepoModel) -> AIContext {
        let queryTerms = normalizedQueryTerms(query)
        let mustInclude = repo.files.filter { AppConstants.mustIncludeNames.contains($0.displayName) }
        let otherFiles = repo.files.filter { !AppConstants.mustIncludeNames.contains($0.displayName) }

        var slices: [ContextSlice] = []
        var usedTokens = 0

        for file in ranked(files: mustInclude, queryTerms: queryTerms) {
            guard usedTokens < AppConstants.aiReservedMustIncludeTokens else { break }
            if let slice = firstSlice(for: file, queryTerms: queryTerms), usedTokens + slice.tokenEstimate <= AppConstants.aiReservedMustIncludeTokens {
                slices.append(slice)
                usedTokens += slice.tokenEstimate
            }
        }

        for file in ranked(files: otherFiles, queryTerms: queryTerms) {
            guard usedTokens < AppConstants.aiMaxEstimatedTokens else { break }
            if let slice = firstSlice(for: file, queryTerms: queryTerms), usedTokens + slice.tokenEstimate <= AppConstants.aiMaxEstimatedTokens {
                slices.append(slice)
                usedTokens += slice.tokenEstimate
            }
        }

        let existingPaths = Set(slices.map(\.filePath))
        for file in ranked(files: repo.files.filter { existingPaths.contains($0.relativePath) }, queryTerms: queryTerms) {
            guard usedTokens < AppConstants.aiMaxEstimatedTokens else { break }
            if let tail = tailSlice(for: file), usedTokens + tail.tokenEstimate <= AppConstants.aiMaxEstimatedTokens {
                slices.append(tail)
                usedTokens += tail.tokenEstimate
            }
        }

        let prompt = promptString(query: query, repo: repo, slices: slices)
        let contextKeySeed = repo.repoHash + query + slices.map { $0.filePath + $0.lineRange + $0.contentHash }.joined(separator: "|")
        return AIContext(prompt: prompt, slices: slices, tokenEstimate: prompt.estimatedTokenCount, cacheKey: contextKeySeed.sha256Hex)
    }

    private func ranked(files: [RepoFile], queryTerms: [String]) -> [RepoFile] {
        files.sorted { lhs, rhs in
            let lhsBoost = queryBoost(for: lhs, queryTerms: queryTerms)
            let rhsBoost = queryBoost(for: rhs, queryTerms: queryTerms)
            let lhsScore = lhs.importanceScore + lhsBoost
            let rhsScore = rhs.importanceScore + rhsBoost

            if lhsScore == rhsScore {
                return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
            }
            return lhsScore > rhsScore
        }
    }

    private func queryBoost(for file: RepoFile, queryTerms: [String]) -> Double {
        guard !queryTerms.isEmpty else { return 0 }
        let haystack = (file.relativePath + "\n" + file.snippet).lowercased()
        let hits = queryTerms.reduce(0) { count, term in
            count + (haystack.contains(term) ? 1 : 0)
        }
        return min(4.0, Double(hits) * 1.1)
    }

    private func firstSlice(for file: RepoFile, queryTerms: [String]) -> ContextSlice? {
        let lines = file.fullPreview.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        guard !lines.isEmpty else { return nil }
        let selected = lines.prefix(AppConstants.aiFirstPassLineLimit).joined(separator: "\n")
        let reason = file.isWhitelisted ? "whitelist + importance" : (queryBoost(for: file, queryTerms: queryTerms) > 0 ? "query match + importance" : "importance")
        return ContextSlice(
            filePath: file.relativePath,
            lineRange: "1-\(min(lines.count, AppConstants.aiFirstPassLineLimit))",
            reason: reason,
            tokenEstimate: selected.estimatedTokenCount + 30,
            contentHash: file.contentHash,
            text: selected
        )
    }

    private func tailSlice(for file: RepoFile) -> ContextSlice? {
        let lines = file.fullPreview.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        guard lines.count > AppConstants.aiFirstPassLineLimit else { return nil }
        let start = AppConstants.aiFirstPassLineLimit
        let end = min(lines.count, AppConstants.aiFirstPassLineLimit + AppConstants.aiTailPassLineLimit)
        let selected = lines[start..<end].joined(separator: "\n")
        return ContextSlice(
            filePath: file.relativePath,
            lineRange: "\(start + 1)-\(end)",
            reason: "tail pass",
            tokenEstimate: selected.estimatedTokenCount + 20,
            contentHash: (file.contentHash + ":tail").sha256Hex,
            text: selected
        )
    }

    private func promptString(query: String, repo: RepoModel, slices: [ContextSlice]) -> String {
        let repoSummary = repo.summary.offlineNarrative
        let sliceBlock = slices.map { slice in
            """
            FILE: \(slice.filePath)
            LINES: \(slice.lineRange)
            REASON: \(slice.reason)
            ---
            \(slice.text)
            """
        }.joined(separator: "\n\n")

        return """
        You are helping a developer understand a code repository.
        Be precise, cite file paths when making claims, and say when the available context is insufficient.

        REPO: \(repo.displayName)
        OFFLINE SUMMARY: \(repoSummary)
        QUESTION: \(query)

        CONTEXT SLICES:
        \(sliceBlock)
        """
    }

    private func normalizedQueryTerms(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 }
    }
}
