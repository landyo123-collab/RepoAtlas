import Foundation

// MARK: - Deterministic Anchor Selection (PADA+ Priority 1)

/// Selects exact evidence spans deterministically from the repo graph and segments,
/// WITHOUT any LLM call. The LLM never invents evidence — it can only condense/rank
/// what this selector has already chosen.
///
/// Anchor types:
///   1. Symbol definition anchors — segments containing definitions matching query symbol hints
///   2. Content match anchors — segments whose content/label match query terms via FTS
///   3. Reference wiring anchors — segments at import/reference line numbers
///   4. Doc/architecture anchors — overview segments from doc and config files
///   5. Test/debugging anchors — test segments mentioning query terms or target symbols
struct DeterministicAnchorSelector {

    /// Result of deterministic anchor selection.
    struct AnchorResult {
        let exactEvidence: [ExactEvidence]
        let supportingContext: [SupportingContext]
        let implementationPath: ImplementationPath
        let anchorStats: AnchorStats
    }

    struct AnchorStats {
        let governingAnchors: Int
        let symbolAnchors: Int
        let contentAnchors: Int
        let referenceAnchors: Int
        let docAnchors: Int
        let testAnchors: Int
        let totalTokens: Int
        let droppedForBudget: Int
    }

    // MARK: - Public API

    /// Select deterministic anchors from ranked candidates.
    /// This replaces the LLM evidence extraction stage entirely for anchor selection.
    func selectAnchors(
        candidates: [String: PADACandidate],
        queryIntent: QueryIntent,
        queryPolicy: QueryPolicy,
        store: RepoMemoryStore,
        passport: String,
        governingFiles: [GoverningFileDetector.GoverningFile] = []
    ) -> AnchorResult {
        var anchors: [ScoredAnchor] = []
        var supportingContext: [SupportingContext] = []
        let tokenBudget = queryPolicy.tokenBudget

        let rankedCandidates = candidates.values.sorted { $0.score > $1.score }
        let selectedCandidates = Array(rankedCandidates.prefix(queryPolicy.maxFiles))

        // Pass 0: Governing file anchors (deep coverage for truth-source docs)
        let govAnchors = selectGoverningAnchors(
            governingFiles: governingFiles,
            queryPolicy: queryPolicy,
            store: store
        )
        anchors.append(contentsOf: govAnchors)

        // Pass 1: Symbol definition anchors
        let symbolAnchors = selectSymbolDefinitionAnchors(
            candidates: selectedCandidates,
            symbolHints: queryIntent.symbolHints,
            store: store
        )
        anchors.append(contentsOf: symbolAnchors)

        // Pass 2: Content match anchors (FTS-informed segment selection)
        let contentAnchors = selectContentMatchAnchors(
            candidates: selectedCandidates,
            queryTerms: queryIntent.extractedTerms,
            store: store,
            excludeSegmentIds: Set(anchors.map(\.segmentId))
        )
        anchors.append(contentsOf: contentAnchors)

        // Pass 3: Reference wiring anchors
        let refAnchors = selectReferenceWiringAnchors(
            candidates: selectedCandidates,
            symbolHints: queryIntent.symbolHints,
            store: store,
            excludeSegmentIds: Set(anchors.map(\.segmentId))
        )
        anchors.append(contentsOf: refAnchors)

        // Pass 4: Doc/architecture anchors
        let (docAnchors, docSupporting) = selectDocAnchors(
            candidates: selectedCandidates,
            queryPolicy: queryPolicy,
            store: store,
            excludeSegmentIds: Set(anchors.map(\.segmentId))
        )
        anchors.append(contentsOf: docAnchors)
        supportingContext.append(contentsOf: docSupporting)

        // Pass 5: Test/debugging anchors
        let testAnchors = selectTestAnchors(
            candidates: selectedCandidates,
            queryIntent: queryIntent,
            queryPolicy: queryPolicy,
            store: store,
            excludeSegmentIds: Set(anchors.map(\.segmentId))
        )
        anchors.append(contentsOf: testAnchors)

        // Deduplicate by (path, segmentId)
        var seen = Set<Int64>()
        anchors = anchors.filter { anchor in
            guard !seen.contains(anchor.segmentId) else { return false }
            seen.insert(anchor.segmentId)
            return true
        }

        // Sort by score descending, then fit within token budget
        anchors.sort { $0.score > $1.score }

        var fittedAnchors: [ScoredAnchor] = []
        var tokensUsed = 0
        var droppedCount = 0
        for anchor in anchors {
            if tokensUsed + anchor.tokenEstimate > tokenBudget {
                droppedCount += 1
                continue
            }
            fittedAnchors.append(anchor)
            tokensUsed += anchor.tokenEstimate
        }

        // Convert to ExactEvidence
        let exactEvidence = fittedAnchors.map { anchor -> ExactEvidence in
            ExactEvidence(
                path: anchor.path,
                lineRange: "\(anchor.startLine)-\(anchor.endLine)",
                symbol: anchor.symbol,
                kind: anchor.kind,
                relevance: min(1.0, anchor.score / 10.0),
                why: anchor.reason,
                excerpt: anchor.content,
                provenance: anchor.provenance
            )
        }

        // Build deterministic implementation path
        let implPath = buildDeterministicImplementationPath(
            anchors: fittedAnchors,
            candidates: candidates,
            symbolHints: queryIntent.symbolHints,
            store: store,
            passport: passport
        )

        let stats = AnchorStats(
            governingAnchors: govAnchors.count,
            symbolAnchors: symbolAnchors.count,
            contentAnchors: contentAnchors.count,
            referenceAnchors: refAnchors.count,
            docAnchors: docAnchors.count,
            testAnchors: testAnchors.count,
            totalTokens: tokensUsed,
            droppedForBudget: droppedCount
        )

        return AnchorResult(
            exactEvidence: exactEvidence,
            supportingContext: supportingContext,
            implementationPath: implPath,
            anchorStats: stats
        )
    }

    // MARK: - Pass 0: Governing File Anchors

    /// Deep segment coverage for governing files (truth-source docs).
    /// Unlike normal docs which get 2 segments, governing files get 4-8 segments
    /// depending on their type and the query type. This ensures DeepSeek sees
    /// the full map/status/zones content instead of just a title + intro.
    private func selectGoverningAnchors(
        governingFiles: [GoverningFileDetector.GoverningFile],
        queryPolicy: QueryPolicy,
        store: RepoMemoryStore
    ) -> [ScoredAnchor] {
        guard !governingFiles.isEmpty else { return [] }
        var anchors: [ScoredAnchor] = []

        for govFile in governingFiles {
            guard let file = store.file(byId: govFile.fileId) else { continue }
            let segments = store.segments(forFileId: govFile.fileId)
            guard !segments.isEmpty else { continue }

            // Determine how many segments to pull based on governing type and query type
            let maxSegs: Int
            switch govFile.governingType {
            case .repoMap:
                maxSegs = queryPolicy.queryType == .wholeSystem ? 8 : 6
            case .readme:
                maxSegs = queryPolicy.queryType == .wholeSystem ? 8 : 6
            case .anchor:
                maxSegs = queryPolicy.queryType == .wholeSystem ? 6 : 4
            case .statusOverview:
                maxSegs = queryPolicy.queryType == .wholeSystem ? 6 : 4
            case .blueprint:
                maxSegs = queryPolicy.queryType == .architecture ? 8 : 6
            case .manifest:
                maxSegs = 4
            case .subtreeReadme:
                maxSegs = queryPolicy.queryType == .wholeSystem ? 4 : 2
            }

            // Base score: governing anchors must survive token budget fitting.
            // They score higher than normal doc anchors (which get ~candidate.score + 2.0)
            let baseScore: Double
            switch govFile.governingType {
            case .repoMap:     baseScore = 18.0
            case .readme:      baseScore = 16.0
            case .anchor:      baseScore = 15.0
            case .statusOverview: baseScore = 14.0
            case .blueprint:   baseScore = 14.0
            case .manifest:    baseScore = 12.0
            case .subtreeReadme: baseScore = 10.0
            }

            // Take up to maxSegs segments, prioritizing content-rich segments
            let sortedSegs = segments.sorted { a, b in
                // Prefer longer segments (more content) but cap extreme values
                let aLen = min(a.tokenEstimate, 800)
                let bLen = min(b.tokenEstimate, 800)
                if aLen != bLen { return aLen > bLen }
                return a.segmentIndex < b.segmentIndex
            }

            for (idx, seg) in sortedSegs.prefix(maxSegs).enumerated() {
                // Decay score slightly for later segments so ordering is preserved
                let segScore = baseScore + govFile.priority - Double(idx) * 0.3

                let prov = [EvidenceProvenance(
                    source: .governing,
                    trigger: "\(govFile.governingType.rawValue):\(govFile.path)",
                    hopDistance: 0,
                    score: segScore
                )]

                anchors.append(ScoredAnchor(
                    segmentId: seg.id,
                    path: govFile.path,
                    startLine: seg.startLine,
                    endLine: seg.endLine,
                    symbol: seg.label,
                    kind: file.fileType == "config" ? "config" : "markdown",
                    content: seg.content,
                    reason: "governing \(govFile.governingType.rawValue): \(govFile.reason) (seg \(idx + 1)/\(min(sortedSegs.count, maxSegs)))",
                    score: segScore,
                    tokenEstimate: seg.tokenEstimate + 30,
                    provenance: prov
                ))
            }
        }

        return anchors
    }

    // MARK: - Pass 1: Symbol Definition Anchors

    /// For each symbol hint from the query, find the segment containing its definition.
    private func selectSymbolDefinitionAnchors(
        candidates: [PADACandidate],
        symbolHints: [String],
        store: RepoMemoryStore
    ) -> [ScoredAnchor] {
        guard !symbolHints.isEmpty else { return [] }
        var anchors: [ScoredAnchor] = []

        for candidate in candidates {
            let symbols = store.symbols(forFileId: candidate.fileId)
            let segments = store.segments(forFileId: candidate.fileId)
            guard !segments.isEmpty else { continue }

            for symbol in symbols {
                // Check if this symbol matches any hint
                let matchedHint = symbolHints.first { hint in
                    symbol.name.localizedCaseInsensitiveContains(hint) ||
                    hint.localizedCaseInsensitiveContains(symbol.name)
                }
                guard let hint = matchedHint else { continue }

                // Find the segment containing this symbol's line number
                guard let seg = segments.first(where: { $0.startLine <= symbol.lineNumber && $0.endLine >= symbol.lineNumber }) else { continue }

                let prov = candidate.provenance + [
                    EvidenceProvenance(source: .ftsSymbol, trigger: "def:\(hint)", hopDistance: 0, score: 8.0)
                ]

                anchors.append(ScoredAnchor(
                    segmentId: seg.id,
                    path: candidate.path,
                    startLine: seg.startLine,
                    endLine: seg.endLine,
                    symbol: symbol.name,
                    kind: symbolKindToEvidenceKind(symbol.kind),
                    content: seg.content,
                    reason: "definition of \(symbol.name) (\(symbol.kind)) matching query symbol '\(hint)'",
                    score: candidate.score + 8.0,
                    tokenEstimate: seg.tokenEstimate + 30,
                    provenance: prov
                ))
            }
        }

        return anchors
    }

    // MARK: - Pass 2: Content Match Anchors

    /// Select segments whose content or label directly matches query terms.
    private func selectContentMatchAnchors(
        candidates: [PADACandidate],
        queryTerms: [String],
        store: RepoMemoryStore,
        excludeSegmentIds: Set<Int64>
    ) -> [ScoredAnchor] {
        guard !queryTerms.isEmpty else { return [] }
        var anchors: [ScoredAnchor] = []
        let termsLower = queryTerms.map { $0.lowercased() }

        for candidate in candidates {
            let segments = store.segments(forFileId: candidate.fileId)

            for seg in segments.prefix(candidate.score >= 5.0 ? 10 : 5) {
                guard !excludeSegmentIds.contains(seg.id) else { continue }

                let contentLower = seg.content.lowercased()
                let labelLower = seg.label.lowercased()

                // Count how many query terms appear in this segment
                var matchCount = 0
                var matchedTerms: [String] = []
                for term in termsLower {
                    if contentLower.contains(term) || labelLower.contains(term) {
                        matchCount += 1
                        matchedTerms.append(term)
                    }
                }

                guard matchCount > 0 else { continue }

                // Score based on match density
                let matchScore = Double(matchCount) * 2.5
                let prov = candidate.provenance + [
                    EvidenceProvenance(source: .ftsContent, trigger: matchedTerms.joined(separator: ","), hopDistance: 0, score: matchScore)
                ]

                anchors.append(ScoredAnchor(
                    segmentId: seg.id,
                    path: candidate.path,
                    startLine: seg.startLine,
                    endLine: seg.endLine,
                    symbol: seg.label,
                    kind: segmentTypeToKind(seg.segmentType, fileType: candidate.fileType),
                    content: seg.content,
                    reason: "content matches \(matchCount) query term(s): \(matchedTerms.prefix(3).joined(separator: ", "))",
                    score: candidate.score + matchScore,
                    tokenEstimate: seg.tokenEstimate + 30,
                    provenance: prov
                ))
            }
        }

        return anchors
    }

    // MARK: - Pass 3: Reference Wiring Anchors

    /// For symbol references pointing to/from candidate files, select the relevant segments.
    private func selectReferenceWiringAnchors(
        candidates: [PADACandidate],
        symbolHints: [String],
        store: RepoMemoryStore,
        excludeSegmentIds: Set<Int64>
    ) -> [ScoredAnchor] {
        var anchors: [ScoredAnchor] = []
        let candidatePaths = Set(candidates.map(\.path))

        for candidate in candidates.prefix(20) {
            let refs = store.referencesFrom(fileId: candidate.fileId)
            let segments = store.segments(forFileId: candidate.fileId)
            guard !segments.isEmpty else { continue }

            for ref in refs {
                // Only anchor references that point to other candidates or match symbol hints
                let isRelevantTarget = candidatePaths.contains(ref.targetPath) ||
                    symbolHints.contains(where: { ref.targetSymbol.localizedCaseInsensitiveContains($0) })
                guard isRelevantTarget else { continue }

                // Find the segment containing this reference
                guard let seg = segments.first(where: { $0.startLine <= ref.lineNumber && $0.endLine >= ref.lineNumber }) else { continue }
                guard !excludeSegmentIds.contains(seg.id) else { continue }

                // Also select import_block segments for wiring context
                let isImport = seg.segmentType == "import_block" || ref.kind == "import"

                let score = isImport ? 2.0 : 3.0
                let prov = [EvidenceProvenance(source: .graphReference, trigger: "\(ref.targetSymbol)@\(ref.targetPath)", hopDistance: 0, score: score)]

                anchors.append(ScoredAnchor(
                    segmentId: seg.id,
                    path: candidate.path,
                    startLine: seg.startLine,
                    endLine: seg.endLine,
                    symbol: ref.targetSymbol,
                    kind: "code",
                    content: seg.content,
                    reason: "references \(ref.targetSymbol) in \(ref.targetPath) (\(ref.kind))",
                    score: candidate.score + score,
                    tokenEstimate: seg.tokenEstimate + 30,
                    provenance: prov
                ))
            }
        }

        return anchors
    }

    // MARK: - Pass 4: Doc/Architecture Anchors

    /// For doc and config files, select overview/summary segments.
    private func selectDocAnchors(
        candidates: [PADACandidate],
        queryPolicy: QueryPolicy,
        store: RepoMemoryStore,
        excludeSegmentIds: Set<Int64>
    ) -> ([ScoredAnchor], [SupportingContext]) {
        var anchors: [ScoredAnchor] = []
        var supporting: [SupportingContext] = []

        let docCandidates = candidates.filter { $0.fileType == "docs" || $0.fileType == "config" }
        guard !docCandidates.isEmpty else { return ([], []) }

        for candidate in docCandidates {
            let segments = store.segments(forFileId: candidate.fileId)
            guard !segments.isEmpty else { continue }

            // For docs: take the first 2 segments (usually overview/introduction)
            // For configs: take the preamble or first chunk
            let maxDocSegs = candidate.fileType == "docs" ? 2 : 1
            for seg in segments.prefix(maxDocSegs) {
                guard !excludeSegmentIds.contains(seg.id) else { continue }

                if queryPolicy.includeDocs || queryPolicy.queryType == .architecture || queryPolicy.queryType == .wholeSystem {
                    // Promote to exact evidence for architecture/whole-system queries
                    let prov = [EvidenceProvenance(source: .structuralRole, trigger: candidate.fileType, hopDistance: 0, score: 2.0)]
                    anchors.append(ScoredAnchor(
                        segmentId: seg.id,
                        path: candidate.path,
                        startLine: seg.startLine,
                        endLine: seg.endLine,
                        symbol: seg.label,
                        kind: candidate.fileType == "docs" ? "markdown" : "config",
                        content: seg.content,
                        reason: "\(candidate.fileType) overview: \(candidate.path)",
                        score: candidate.score + 2.0,
                        tokenEstimate: seg.tokenEstimate + 20,
                        provenance: prov
                    ))
                } else {
                    // Demote to supporting context for implementation/debugging queries
                    supporting.append(SupportingContext(
                        path: candidate.path,
                        kind: candidate.fileType,
                        why: "\(candidate.fileType) context for \(candidate.path)",
                        excerpt: String(seg.content.prefix(500))
                    ))
                }
            }
        }

        return (anchors, supporting)
    }

    // MARK: - Pass 5: Test/Debugging Anchors

    /// For test files, select segments that reference query terms or target symbols.
    private func selectTestAnchors(
        candidates: [PADACandidate],
        queryIntent: QueryIntent,
        queryPolicy: QueryPolicy,
        store: RepoMemoryStore,
        excludeSegmentIds: Set<Int64>
    ) -> [ScoredAnchor] {
        guard queryPolicy.includeTests || queryPolicy.queryType == .debugging else { return [] }

        var anchors: [ScoredAnchor] = []
        let testCandidates = candidates.filter { $0.fileType == "test" }
        let allTerms = (queryIntent.extractedTerms + queryIntent.symbolHints).map { $0.lowercased() }

        for candidate in testCandidates {
            let segments = store.segments(forFileId: candidate.fileId)

            for seg in segments.prefix(6) {
                guard !excludeSegmentIds.contains(seg.id) else { continue }
                let contentLower = seg.content.lowercased()

                let matchCount = allTerms.filter { contentLower.contains($0) }.count
                guard matchCount > 0 else { continue }

                let score = Double(matchCount) * 1.5
                let prov = [EvidenceProvenance(source: .structuralRole, trigger: "test", hopDistance: 0, score: score)]

                anchors.append(ScoredAnchor(
                    segmentId: seg.id,
                    path: candidate.path,
                    startLine: seg.startLine,
                    endLine: seg.endLine,
                    symbol: seg.label,
                    kind: "test",
                    content: seg.content,
                    reason: "test segment matching \(matchCount) query term(s)",
                    score: candidate.score + score,
                    tokenEstimate: seg.tokenEstimate + 30,
                    provenance: prov
                ))
            }
        }

        return anchors
    }

    // MARK: - Deterministic Implementation Path

    /// Build an implementation path from anchor evidence without LLM.
    /// Traces the call/import chain from entrypoints through orchestrators to services.
    private func buildDeterministicImplementationPath(
        anchors: [ScoredAnchor],
        candidates: [String: PADACandidate],
        symbolHints: [String],
        store: RepoMemoryStore,
        passport: String
    ) -> ImplementationPath {
        // Group anchors by path and assign roles based on file properties
        var steps: [ImplementationStep] = []
        var seenPaths = Set<String>()

        // Sort anchors: entrypoints first, then by score
        let sortedAnchors = anchors.sorted { a, b in
            let aIsEntry = candidates[a.path]?.roleTags.contains("entrypoint") ?? false
            let bIsEntry = candidates[b.path]?.roleTags.contains("entrypoint") ?? false
            if aIsEntry != bIsEntry { return aIsEntry }
            return a.score > b.score
        }

        for (idx, anchor) in sortedAnchors.enumerated() {
            guard !seenPaths.contains(anchor.path) else { continue }
            guard steps.count < 12 else { break }
            seenPaths.insert(anchor.path)

            let candidate = candidates[anchor.path]
            let role = inferRole(fileType: candidate?.fileType ?? "", roleTags: candidate?.roleTags ?? [], segmentType: anchor.kind)

            steps.append(ImplementationStep(
                order: steps.count + 1,
                path: anchor.path,
                symbol: anchor.symbol,
                role: role,
                whyItMatters: anchor.reason,
                confidence: min(1.0, anchor.score / 10.0)
            ))
        }

        let summary: String
        if steps.isEmpty {
            summary = "No implementation path could be determined from the available evidence."
        } else {
            let pathDesc = steps.prefix(5).map { "[\($0.role)] \($0.path):\($0.symbol)" }.joined(separator: " → ")
            summary = "Deterministic path through \(steps.count) files: \(pathDesc)"
        }

        return ImplementationPath(summary: summary, steps: steps)
    }

    // MARK: - Helpers

    private func symbolKindToEvidenceKind(_ kind: String) -> String {
        switch kind {
        case "class", "struct", "enum", "protocol", "extension", "function", "method":
            return "code"
        default:
            return "code"
        }
    }

    private func segmentTypeToKind(_ segType: String, fileType: String) -> String {
        if fileType == "docs" { return "markdown" }
        if fileType == "config" { return "config" }
        if fileType == "test" { return "test" }
        return "code"
    }

    private func inferRole(fileType: String, roleTags: [String], segmentType: String) -> String {
        if roleTags.contains("entrypoint") { return "entrypoint" }
        if roleTags.contains("manifest") { return "config" }
        if fileType == "test" { return "test" }
        if fileType == "docs" { return "doc" }
        if fileType == "config" { return "config" }
        if roleTags.contains("viewController") || roleTags.contains("view") { return "ui" }
        if roleTags.contains("model") { return "storage" }
        // Heuristic: files with many outgoing refs are orchestrators
        return "service"
    }
}

// MARK: - Internal scored anchor type

private struct ScoredAnchor {
    let segmentId: Int64
    let path: String
    let startLine: Int
    let endLine: Int
    let symbol: String
    let kind: String
    let content: String
    let reason: String
    let score: Double
    let tokenEstimate: Int
    let provenance: [EvidenceProvenance]
}
