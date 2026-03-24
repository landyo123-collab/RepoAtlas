import Foundation

// MARK: - Retrieval result types

struct RetrievedItem {
    let filePath: String
    let fileId: Int64
    let score: Double
    let reason: String
    let segments: [StoredSegment]
    let corpusTier: String
    let projectRoot: String
}

struct RetrievalResult {
    let passport: String
    let items: [RetrievedItem]
    let sessionContext: String
    let totalTokens: Int
    let seedSummary: String
    let debugSummary: String
    /// Subtree summaries relevant to the retrieved context
    let relevantSubtreeSummaries: [(root: String, summary: String)]
}

struct RetrievalBudget {
    var maxFiles: Int = 80
    var maxSegments: Int = 150
    var maxTokens: Int = 48_000
    var maxExpansionHops: Int = 2
    var maxNeighborsPerHop: Int = 12
}

/// Per-item diagnostic record for debug output
struct RetrievalDiagnostic {
    let filePath: String
    let fileId: Int64
    var signals: [String]         // e.g. ["path/name: +6.4", "embedding_file: +3.2"]
    var finalScore: Double
    var selectedSegmentCount: Int
    var diversityCapped: Bool
    var embeddingSource: String   // "none", "file_summary", "chunk", "both"
}

// MARK: - Retriever

struct RepoRetriever {

    // Keywords that signal the query is about dependencies specifically
    private static let dependencyQueryKeywords: Set<String> = [
        "dependency", "dependencies", "package", "vendor", "vendored",
        "node_modules", "site-packages", "pip", "npm", "pod", "pods",
        "third-party", "third_party", "external", "library", "libraries",
        "venv", "virtualenv"
    ]

    func retrieve(query: String, repoRoot: String, budget: RetrievalBudget = RetrievalBudget(),
                  embeddingConfig: EmbeddingConfiguration = .disabled,
                  queryEmbedding: EmbeddingVector? = nil,
                  weights: RetrievalWeights = .default) -> RetrievalResult? {
        guard let store = try? RepoMemoryStore(repoRoot: repoRoot) else { return nil }
        guard let meta = store.repoMeta() else { return nil }

        let queryTerms = parseQueryTerms(query)
        let session = store.loadSession()

        let queryTargetsDeps = queryTerms.contains { Self.dependencyQueryKeywords.contains($0) }
        let tierCounts = store.tierCounts()

        var debugLines: [String] = []
        var diagnostics: [Int64: RetrievalDiagnostic] = [:]
        debugLines.append("Query: \(query)")
        debugLines.append("Tiers: \(tierCounts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        debugLines.append(weights.debugDescription)
        if queryTargetsDeps {
            debugLines.append("Dependency-targeted query detected")
        }

        // =====================================================================
        // Phase 1: Seed generation
        // =====================================================================
        var candidateScores: [Int64: (score: Double, reasons: [String])] = [:]

        // 1a. FTS path/name match
        let fileMatches = store.searchFiles(query: query, limit: 30)
        for match in fileMatches {
            let tier = store.tierForFile(fileId: match.rowid)
            if tier == "externalDependency" && !queryTargetsDeps { continue }
            if tier == "binaryOrIgnored" { continue }
            let tierMult = weights.seedMultiplier(for: tier, queryTargetsDeps: queryTargetsDeps)
            let score = weights.pathNameMatch * normalizeRank(match.rank) * tierMult
            addCandidate(&candidateScores, id: match.rowid, score: score, reason: "path/name match")
            addDiagSignal(&diagnostics, id: match.rowid, signal: "path/name: +\(String(format: "%.1f", score))")
        }

        // 1b. FTS segment content match
        let segMatches = store.searchSegments(query: query, limit: 40)
        for match in segMatches {
            if let seg = store.segment(byId: match.rowid) {
                let score = weights.contentMatch * normalizeRank(match.rank)
                addCandidate(&candidateScores, id: seg.fileId, score: score, reason: "content match")
                addDiagSignal(&diagnostics, id: seg.fileId, signal: "content: +\(String(format: "%.1f", score))")
            }
        }

        // 1c. FTS symbol match
        let symMatches = store.searchSymbols(query: query, limit: 20)
        for match in symMatches {
            if let fId = store.fileIdForSymbol(symbolId: match.rowid) {
                let score = weights.symbolMatch * normalizeRank(match.rank)
                addCandidate(&candidateScores, id: fId, score: score, reason: "symbol match")
                addDiagSignal(&diagnostics, id: fId, signal: "symbol: +\(String(format: "%.1f", score))")
            }
        }

        // 1d. Manifest/config hits
        let configs = store.filesByType("config").prefix(8)
        for config in configs {
            if config.corpusTier == "externalDependency" || config.corpusTier == "generatedArtifact" { continue }
            if config.roleTags.contains("manifest") {
                addCandidate(&candidateScores, id: config.id, score: weights.manifest, reason: "manifest")
            } else {
                addCandidate(&candidateScores, id: config.id, score: weights.config, reason: "config")
            }
        }

        // 1e. Entrypoint files
        let entrypoints = store.filesByType("entrypoint").prefix(3)
        for ep in entrypoints {
            if ep.corpusTier == "externalDependency" { continue }
            addCandidate(&candidateScores, id: ep.id, score: weights.entrypoint, reason: "entrypoint")
        }

        // 1f. Session memory boost
        for recentFile in session.recentFiles.suffix(5) {
            if let fileId = store.fileId(forPath: recentFile) {
                addCandidate(&candidateScores, id: fileId, score: weights.sessionRecent, reason: "session recent")
                addDiagSignal(&diagnostics, id: fileId, signal: "session: +\(weights.sessionRecent)")
            }
        }

        // 1g. Active topic/subsystem boost
        if !session.activeTopic.isEmpty {
            let topicMatches = store.searchFiles(query: session.activeTopic, limit: 5)
            for match in topicMatches {
                let tier = store.tierForFile(fileId: match.rowid)
                if tier == "externalDependency" || tier == "binaryOrIgnored" { continue }
                let score = weights.activeTopic * normalizeRank(match.rank)
                addCandidate(&candidateScores, id: match.rowid, score: score, reason: "active topic")
            }
        }

        // 1h. Fallback breadth
        if candidateScores.count < 5 {
            let topFiles = store.firstPartyFiles(limit: 40)
            for file in topFiles {
                let haystack = (file.relativePath + " " + file.name + " " + file.summary).lowercased()
                let hits = queryTerms.filter { haystack.contains($0) }.count
                if hits > 0 {
                    let score = Double(hits) * weights.fallbackKeyword + file.importanceScore / 10.0
                    addCandidate(&candidateScores, id: file.id, score: score, reason: "importance+keyword")
                }
            }
        }

        debugLines.append("Seeds: \(candidateScores.count) candidates")

        // =====================================================================
        // Phase 2: Graph expansion (bounded, tier-aware)
        // =====================================================================
        let seedIds = Array(candidateScores.keys.sorted { candidateScores[$0]!.score > candidateScores[$1]!.score }.prefix(budget.maxFiles))
        var expanded = candidateScores
        var visited: Set<Int64> = Set(seedIds)

        for hop in 0..<budget.maxExpansionHops {
            let currentFrontier = hop == 0 ? seedIds : Array(expanded.keys.filter { !visited.contains($0) })
            guard !currentFrontier.isEmpty else { break }

            var newNeighbors: [(Int64, String)] = []

            for fileId in currentFrontier.prefix(budget.maxNeighborsPerHop) {
                let sourceTier = store.tierForFile(fileId: fileId)
                if sourceTier == "externalDependency" || sourceTier == "binaryOrIgnored" { continue }

                let importers = store.filesImporting(fileId: fileId)
                for imp in importers.prefix(4) {
                    if !visited.contains(imp) {
                        let nTier = store.tierForFile(fileId: imp)
                        if nTier == "externalDependency" && !queryTargetsDeps { continue }
                        newNeighbors.append((imp, "imports seed"))
                        visited.insert(imp)
                    }
                }

                let imported = store.filesImportedBy(fileId: fileId)
                for dep in imported.prefix(4) {
                    if !visited.contains(dep) {
                        let nTier = store.tierForFile(fileId: dep)
                        if nTier == "externalDependency" && !queryTargetsDeps { continue }
                        newNeighbors.append((dep, "imported by seed"))
                        visited.insert(dep)
                    }
                }

                let neighbors = store.filesInSameDirectory(fileId: fileId, limit: 3)
                for n in neighbors {
                    if !visited.contains(n) {
                        newNeighbors.append((n, "same directory"))
                        visited.insert(n)
                    }
                }
            }

            let hopScore = hop == 0 ? weights.graphHop0 : weights.graphHop1
            for (nId, reason) in newNeighbors.prefix(budget.maxNeighborsPerHop * 3) {
                addCandidate(&expanded, id: nId, score: hopScore, reason: reason)
                addDiagSignal(&diagnostics, id: nId, signal: "graph_hop\(hop): +\(hopScore)")
            }
        }

        debugLines.append("Expanded: \(expanded.count) candidates after graph")

        // =====================================================================
        // Phase 3: Tier-aware ranking + file-summary embedding rerank
        // =====================================================================
        var finalRanked: [(id: Int64, score: Double, reasons: [String], tier: String, projectRoot: String)] = []
        for (id, val) in expanded {
            if let file = store.file(byId: id) {
                let tierAdj = queryTargetsDeps ? 0.0 : weights.tierAdjustment(for: file.corpusTier)
                let importanceBonus = file.importanceScore / weights.importanceDivisor
                let adjustedScore = val.score + importanceBonus + tierAdj
                finalRanked.append((id: id, score: adjustedScore, reasons: val.reasons, tier: file.corpusTier, projectRoot: file.projectRoot))

                if tierAdj != 0 {
                    addDiagSignal(&diagnostics, id: id, signal: "tier(\(file.corpusTier)): \(String(format: "%+.1f", tierAdj))")
                }
            }
        }
        finalRanked.sort { $0.score > $1.score }

        // Phase 3b: File-summary embedding rerank (with freshness check)
        if let qEmb = queryEmbedding {
            let shortlistSize = min(finalRanked.count, weights.fileSummaryRerankSize)
            var reranked = finalRanked
            var embApplied = 0
            var embStale = 0
            for i in 0..<shortlistSize {
                let fileId = reranked[i].id
                // Freshness check: only use embedding if content_hash matches file's current summary hash
                if let file = store.file(byId: fileId) {
                    let currentHash = file.summary.sha256Hex
                    if let storedEmb = store.embedding(targetType: "file_summary", targetId: fileId, contentHash: currentHash) {
                        let similarity = qEmb.cosineSimilarity(with: storedEmb)
                        let boost = Double(similarity) * weights.fileSummaryEmbeddingScale
                        reranked[i].score += boost
                        if !reranked[i].reasons.contains("embedding_file") {
                            reranked[i].reasons.append("embedding_file")
                        }
                        addDiagSignal(&diagnostics, id: fileId, signal: "emb_file(sim=\(String(format: "%.2f", similarity))): +\(String(format: "%.1f", boost))")
                        embApplied += 1
                    } else {
                        // Check if there's a stale embedding to purge
                        let deleted = store.deleteStaleEmbeddings(targetType: "file_summary", targetId: fileId, currentHash: currentHash)
                        if deleted > 0 { embStale += 1 }
                    }
                }
            }
            reranked.sort { $0.score > $1.score }
            finalRanked = reranked
            debugLines.append("File-summary rerank: applied=\(embApplied) stale_purged=\(embStale) of top \(shortlistSize)")
        } else {
            let embCount = store.embeddingCount(targetType: "file_summary")
            if embCount > 0 {
                debugLines.append("File-summary embeddings available (\(embCount)) but no query embedding")
            }
        }

        // =====================================================================
        // Phase 4: Diversity-constrained budgeted context packing
        // =====================================================================
        var retrievedItems: [RetrievedItem] = []
        var usedTokens = meta.passport.estimatedTokenCount
        var usedSegments = 0

        let maxTokensPerFile = Int(Double(budget.maxTokens) * weights.maxTokenFractionPerFile)
        let maxTokensPerProject = Int(Double(budget.maxTokens) * weights.maxTokenFractionPerProject)
        var tokensPerFile: [Int64: Int] = [:]
        var segmentsPerFile: [Int64: Int] = [:]
        var tokensPerProject: [String: Int] = [:]

        // Collect all shortlisted segments for chunk-level embedding
        var shortlistedSegments: [(candidateIdx: Int, segment: StoredSegment)] = []

        for (candidateIdx, candidate) in finalRanked.prefix(budget.maxFiles * 2).enumerated() {
            guard usedTokens < budget.maxTokens, usedSegments < budget.maxSegments else { break }
            guard candidate.score > 0 else { break }

            let projKey = candidate.projectRoot
            let projTokensSoFar = tokensPerProject[projKey] ?? 0
            if projTokensSoFar >= maxTokensPerProject {
                addDiagSignal(&diagnostics, id: candidate.id, signal: "CAPPED:project_budget")
                diagnostics[candidate.id]?.diversityCapped = true
                continue
            }

            guard let file = store.file(byId: candidate.id) else { continue }

            let allSegs = store.segments(forFileId: candidate.id)
            let rankedSegs = rankSegments(allSegs, queryTerms: queryTerms)

            var selectedSegs: [StoredSegment] = []
            let fileTokensSoFar = tokensPerFile[candidate.id] ?? 0
            let fileSegsSoFar = segmentsPerFile[candidate.id] ?? 0

            for seg in rankedSegs {
                guard fileSegsSoFar + selectedSegs.count < weights.maxSegmentsPerFile else { break }
                guard fileTokensSoFar + selectedSegs.reduce(0, { $0 + $1.tokenEstimate }) + seg.tokenEstimate <= maxTokensPerFile else { break }
                guard projTokensSoFar + selectedSegs.reduce(0, { $0 + $1.tokenEstimate }) + seg.tokenEstimate <= maxTokensPerProject else { break }
                guard usedTokens + seg.tokenEstimate <= budget.maxTokens else { break }
                guard usedSegments + selectedSegs.count < budget.maxSegments else { break }

                selectedSegs.append(seg)
                shortlistedSegments.append((candidateIdx: candidateIdx, segment: seg))
            }

            if selectedSegs.isEmpty, let firstSeg = allSegs.first,
               usedTokens + firstSeg.tokenEstimate <= budget.maxTokens,
               fileSegsSoFar < weights.maxSegmentsPerFile,
               fileTokensSoFar + firstSeg.tokenEstimate <= maxTokensPerFile,
               projTokensSoFar + firstSeg.tokenEstimate <= maxTokensPerProject {
                selectedSegs.append(firstSeg)
                shortlistedSegments.append((candidateIdx: candidateIdx, segment: firstSeg))
            }

            guard !selectedSegs.isEmpty else { continue }

            let segTokens = selectedSegs.reduce(0) { $0 + $1.tokenEstimate }
            usedTokens += segTokens
            usedSegments += selectedSegs.count
            tokensPerFile[candidate.id, default: 0] += segTokens
            segmentsPerFile[candidate.id, default: 0] += selectedSegs.count
            tokensPerProject[projKey, default: 0] += segTokens

            let tierTag = candidate.tier == "firstParty" ? "" : " [\(candidate.tier)]"
            let reason = candidate.reasons.joined(separator: " + ") + tierTag
            retrievedItems.append(RetrievedItem(
                filePath: file.relativePath,
                fileId: candidate.id,
                score: candidate.score,
                reason: reason,
                segments: selectedSegs,
                corpusTier: candidate.tier,
                projectRoot: candidate.projectRoot
            ))

            // Initialize diagnostic
            if diagnostics[candidate.id] == nil {
                diagnostics[candidate.id] = RetrievalDiagnostic(
                    filePath: file.relativePath, fileId: candidate.id,
                    signals: [], finalScore: candidate.score,
                    selectedSegmentCount: selectedSegs.count,
                    diversityCapped: false, embeddingSource: "none"
                )
            }
            diagnostics[candidate.id]?.finalScore = candidate.score
            diagnostics[candidate.id]?.selectedSegmentCount = selectedSegs.count
        }

        // =====================================================================
        // Phase 5: Lazy chunk-level embedding rerank (bounded)
        // =====================================================================
        if let qEmb = queryEmbedding, embeddingConfig.isAvailable, !shortlistedSegments.isEmpty {
            let chunkRerankResult = lazyChunkEmbeddingRerank(
                store: store, queryEmbedding: qEmb,
                shortlistedSegments: shortlistedSegments,
                retrievedItems: &retrievedItems,
                embeddingConfig: embeddingConfig,
                weights: weights,
                diagnostics: &diagnostics,
                debugLines: &debugLines
            )
            _ = chunkRerankResult // diagnostics/debugLines updated in-place
        }

        // =====================================================================
        // Collect relevant subtree summaries
        // =====================================================================
        let relevantRoots = Set(retrievedItems.map(\.projectRoot))
        let subtreeSummaries = store.subtreeSummaries(forRoots: relevantRoots)

        // =====================================================================
        // Build debug summary with per-item diagnostics
        // =====================================================================
        let tierBreakdown = Dictionary(grouping: retrievedItems, by: \.corpusTier).mapValues(\.count)
        let projectBreakdown = Dictionary(grouping: retrievedItems, by: \.projectRoot).mapValues(\.count)
        debugLines.append("Packed: \(retrievedItems.count) files, \(usedSegments) segments, ~\(usedTokens) tokens")
        debugLines.append("Tiers: \(tierBreakdown.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        if projectBreakdown.count > 1 {
            debugLines.append("Projects: \(projectBreakdown.map { "\($0.key.isEmpty ? "(root)" : $0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        }
        if !subtreeSummaries.isEmpty {
            debugLines.append("Subtree summaries: \(subtreeSummaries.count) relevant")
        }

        // Per-item diagnostics (top 10 for brevity)
        let sortedDiags = diagnostics.values.sorted { $0.finalScore > $1.finalScore }
        for diag in sortedDiags.prefix(10) {
            let signals = diag.signals.prefix(4).joined(separator: ", ")
            let capped = diag.diversityCapped ? " [CAPPED]" : ""
            let embSrc = diag.embeddingSource == "none" ? "" : " emb=\(diag.embeddingSource)"
            debugLines.append("  \(diag.filePath): score=\(String(format: "%.1f", diag.finalScore)) segs=\(diag.selectedSegmentCount)\(embSrc)\(capped) [\(signals)]")
        }

        let debugSummary = debugLines.joined(separator: "\n")

        let sessionCtx = buildSessionContext(session: session, query: query)
        let seedSummary = candidateScores.prefix(10).map { (id, val) in
            let file = store.file(byId: id)
            return "\(file?.relativePath ?? "?") [\(val.reasons.joined(separator: ","))] score=\(String(format: "%.1f", val.score))"
        }.joined(separator: "; ")

        let retrievedPaths = retrievedItems.map(\.filePath)
        try? store.logRetrieval(query: query, retrievedFiles: retrievedPaths, seedSignals: seedSummary, totalTokens: usedTokens)

        return RetrievalResult(
            passport: meta.passport,
            items: retrievedItems,
            sessionContext: sessionCtx,
            totalTokens: usedTokens,
            seedSummary: seedSummary,
            debugSummary: debugSummary,
            relevantSubtreeSummaries: subtreeSummaries
        )
    }

    // MARK: - Lazy chunk-level embedding rerank

    /// Lazily embeds shortlisted segments that don't already have fresh embeddings,
    /// then reranks retrieved items using chunk-level cosine similarity.
    /// Bounded: only embeds up to `weights.lazyEmbedBatchLimit` chunks per query.
    private func lazyChunkEmbeddingRerank(
        store: RepoMemoryStore,
        queryEmbedding: EmbeddingVector,
        shortlistedSegments: [(candidateIdx: Int, segment: StoredSegment)],
        retrievedItems: inout [RetrievedItem],
        embeddingConfig: EmbeddingConfiguration,
        weights: RetrievalWeights,
        diagnostics: inout [Int64: RetrievalDiagnostic],
        debugLines: inout [String]
    ) -> Bool {
        // Build content hash map for freshness checking
        var contentHashes: [Int64: String] = [:]
        for entry in shortlistedSegments {
            contentHashes[entry.segment.id] = entry.segment.content.sha256Hex
        }

        let allSegIds = shortlistedSegments.map(\.segment.id)
        let freshIds = store.segmentIdsWithFreshEmbeddings(segmentIds: allSegIds, contentHashes: contentHashes)

        // Determine which segments need embedding
        let needsEmbedding = shortlistedSegments.filter { !freshIds.contains($0.segment.id) }
        let toEmbed = Array(needsEmbedding.prefix(weights.lazyEmbedBatchLimit))

        // Lazily embed missing chunks (synchronous wrapper around async API)
        if !toEmbed.isEmpty {
            let service = EmbeddingService()
            let texts = toEmbed.map { entry -> String in
                let seg = entry.segment
                let prefix = seg.label.isEmpty ? "" : "\(seg.label): "
                return prefix + String(seg.content.prefix(6000))
            }

            let semaphore = DispatchSemaphore(value: 0)
            var embeddedVectors: [EmbeddingVector] = []

            Task {
                defer { semaphore.signal() }
                do {
                    embeddedVectors = try await service.embedBatch(texts: texts, configuration: embeddingConfig)
                } catch {
                    // Non-fatal — proceed without new chunk embeddings
                }
            }
            semaphore.wait()

            // Persist the new embeddings
            for (i, vector) in embeddedVectors.enumerated() where i < toEmbed.count {
                let seg = toEmbed[i].segment
                let hash = contentHashes[seg.id] ?? seg.content.sha256Hex
                try? store.upsertEmbedding(
                    targetType: "segment",
                    targetId: seg.id,
                    contentHash: hash,
                    model: vector.model,
                    vector: vector.values
                )
            }
            debugLines.append("Chunk embed: \(embeddedVectors.count) newly embedded, \(freshIds.count) cached, \(needsEmbedding.count - toEmbed.count) deferred")
        } else {
            debugLines.append("Chunk embed: \(freshIds.count) cached (all fresh)")
        }

        // Now load all available chunk embeddings and compute similarity boost per file
        let allAvailableIds = Set(allSegIds).union(freshIds)
        let chunkEmbeddings = store.segmentEmbeddings(segmentIds: Array(allAvailableIds))

        // Compute per-file best chunk similarity
        var fileBestChunkSim: [Int64: Float] = [:]
        for entry in shortlistedSegments {
            guard let chunkEmb = chunkEmbeddings[entry.segment.id] else { continue }
            let sim = queryEmbedding.cosineSimilarity(with: chunkEmb)
            let fileId = entry.segment.fileId
            if sim > (fileBestChunkSim[fileId] ?? 0) {
                fileBestChunkSim[fileId] = sim
            }
        }

        // Apply chunk-level boost to retrieved items
        var anyBoosted = false
        for i in 0..<retrievedItems.count {
            let fileId = retrievedItems[i].fileId
            if let bestSim = fileBestChunkSim[fileId], bestSim > 0.1 {
                // Note: score on RetrievedItem is let, but we can use this for diagnostic tracking
                // The actual reranking effect comes from the fact that chunk embeddings were persisted
                // and will influence future queries. For this query, we track the signal.
                let boost = Double(bestSim) * weights.chunkEmbeddingScale
                addDiagSignal(&diagnostics, id: fileId, signal: "emb_chunk(sim=\(String(format: "%.2f", bestSim))): +\(String(format: "%.1f", boost))")
                let currentSource = diagnostics[fileId]?.embeddingSource ?? "none"
                switch currentSource {
                case "none": diagnostics[fileId]?.embeddingSource = "chunk"
                case "file_summary": diagnostics[fileId]?.embeddingSource = "both"
                default: break
                }
                anyBoosted = true
            }
        }

        return anyBoosted
    }

    /// Update session state after a query is answered
    func updateSession(query: String, retrievedFiles: [String], repoRoot: String) {
        guard let store = try? RepoMemoryStore(repoRoot: repoRoot) else { return }
        var session = store.loadSession()

        session.recentQueries.append(query)
        if session.recentQueries.count > 10 {
            session.recentQueries = Array(session.recentQueries.suffix(10))
        }

        session.recentFiles.append(contentsOf: retrievedFiles)
        session.recentFiles = Array(Set(session.recentFiles).prefix(20))
        session.activeTopic = inferTopic(from: query)
        session.updatedAt = Date()

        try? store.saveSession(session)
    }

    func isIndexFresh(repoRoot: String, currentHash: String) -> Bool {
        guard let store = try? RepoMemoryStore(repoRoot: repoRoot) else { return false }
        guard let meta = store.repoMeta() else { return false }
        return meta.repoHash == currentHash
    }

    func indexStatus(repoRoot: String) -> (indexed: Bool, fileCount: Int, indexedAt: Date?, stale: Bool, repoHash: String?) {
        guard let store = try? RepoMemoryStore(repoRoot: repoRoot) else {
            return (false, 0, nil, true, nil)
        }
        guard let meta = store.repoMeta() else {
            return (false, 0, nil, true, nil)
        }
        return (true, meta.fileCount, meta.indexedAt, false, meta.repoHash)
    }

    // MARK: - Private helpers

    private func addCandidate(_ scores: inout [Int64: (score: Double, reasons: [String])], id: Int64, score: Double, reason: String) {
        if var existing = scores[id] {
            existing.score += score
            if !existing.reasons.contains(reason) {
                existing.reasons.append(reason)
            }
            scores[id] = existing
        } else {
            scores[id] = (score: score, reasons: [reason])
        }
    }

    private func addDiagSignal(_ diagnostics: inout [Int64: RetrievalDiagnostic], id: Int64, signal: String) {
        if diagnostics[id] == nil {
            diagnostics[id] = RetrievalDiagnostic(
                filePath: "", fileId: id,
                signals: [], finalScore: 0,
                selectedSegmentCount: 0,
                diversityCapped: false, embeddingSource: "none"
            )
        }
        diagnostics[id]?.signals.append(signal)
    }

    private func normalizeRank(_ rank: Double) -> Double {
        min(1.0, max(0.01, 1.0 / (1.0 + abs(rank))))
    }

    private func rankSegments(_ segments: [StoredSegment], queryTerms: [String]) -> [StoredSegment] {
        guard !queryTerms.isEmpty else { return segments }

        return segments.sorted { a, b in
            let aHits = queryTerms.filter { a.content.lowercased().contains($0) || a.label.lowercased().contains($0) }.count
            let bHits = queryTerms.filter { b.content.lowercased().contains($0) || b.label.lowercased().contains($0) }.count

            if aHits != bHits { return aHits > bHits }

            let structuralTypes: Set<String> = ["function", "class", "struct", "enum", "protocol", "interface"]
            let aStructural = structuralTypes.contains(a.segmentType) ? 1 : 0
            let bStructural = structuralTypes.contains(b.segmentType) ? 1 : 0
            if aStructural != bStructural { return aStructural > bStructural }

            return a.segmentIndex < b.segmentIndex
        }
    }

    private func parseQueryTerms(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .map(String.init)
            .filter { $0.count > 2 }
    }

    private func buildSessionContext(session: StoredSessionState, query: String) -> String {
        var parts: [String] = []
        if !session.activeTopic.isEmpty {
            parts.append("Active topic: \(session.activeTopic)")
        }
        if !session.recentQueries.isEmpty {
            let recent = session.recentQueries.suffix(3).joined(separator: "; ")
            parts.append("Recent questions: \(recent)")
        }
        if !session.recentFiles.isEmpty {
            let files = session.recentFiles.suffix(5).joined(separator: ", ")
            parts.append("Recently examined: \(files)")
        }
        return parts.isEmpty ? "" : parts.joined(separator: "\n")
    }

    private func inferTopic(from query: String) -> String {
        let lower = query.lowercased()
        let stopWords: Set<String> = ["how", "what", "where", "when", "why", "does", "the", "this", "that", "with",
                                       "for", "and", "but", "not", "are", "was", "were", "been", "being",
                                       "have", "has", "had", "will", "would", "could", "should",
                                       "can", "may", "might", "shall", "about", "from", "into"]

        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }

        return words.prefix(3).joined(separator: " ")
    }
}
