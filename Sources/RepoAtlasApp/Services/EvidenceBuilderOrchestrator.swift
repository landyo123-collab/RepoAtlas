import Foundation

// MARK: - PADA+ Evidence Builder Orchestrator

/// Provenance-Aware Dossier Assembler.
/// Deterministic-first architecture: graph and FTS discovery runs before any LLM call.
/// LLM is used only for screening/extraction after deterministic narrowing.
///
/// Pipeline stages:
///   1. Deterministic query classification (no LLM)
///   2. Deterministic candidate discovery (FTS + graph + structural roles)
///   3. LLM-guided candidate screening (batched, optional)
///   4. Query-type-aware graph expansion (deterministic)
///   5. Targeted evidence extraction (LLM, batched)
///   6. Structural coverage computation + dossier assembly
struct EvidenceBuilderOrchestrator {

    private let service = EvidenceBuilderService()
    private let classifier = QueryPolicyClassifier()
    private let anchorSelector = DeterministicAnchorSelector()
    private let docLinker = DocCodeLinker()
    private let governingDetector = GoverningFileDetector()

    // MARK: - Public API

    /// Build an evidence dossier for the given query.
    /// Returns nil if the builder is unavailable or fails (caller should fall back).
    func buildDossier(
        query: String,
        repoRoot: String,
        initialRetrieval: RetrievalResult?,
        configuration: EvidenceBuilderConfiguration,
        deepSeekConfig: DeepSeekConfiguration? = nil,
        progress: @escaping (String) -> Void
    ) async -> EvidenceDossier? {
        let startTime = CFAbsoluteTimeGetCurrent()
        var stages: [StageLog] = []
        var totalBuilderTokens = 0
        var usedModel = configuration.model.isEmpty ? EvidenceBuilderConfiguration.defaultModel : configuration.model
        var usedFallback = false

        guard configuration.isAvailable else { return nil }
        guard let store = try? RepoMemoryStore(repoRoot: repoRoot) else { return nil }
        guard let meta = store.repoMeta() else { return nil }

        let totalFirstPartyFiles = store.firstPartyFiles(limit: 100_000).count
        let dossierCache = DossierCache(repoRoot: repoRoot)

        // =====================================================================
        // Stage 1: Deterministic Query Classification (NO LLM)
        // =====================================================================
        progress("PADA+: classifying query (deterministic)...")
        let stage1Start = CFAbsoluteTimeGetCurrent()

        let (queryIntent, queryPolicy) = classifier.classify(query: query, repoFileCount: totalFirstPartyFiles)

        stages.append(StageLog(
            name: "query_classification",
            candidatesIn: 0, candidatesOut: 0,
            tokensUsed: 0,
            durationMs: Int((CFAbsoluteTimeGetCurrent() - stage1Start) * 1000),
            notes: "type=\(queryIntent.primary.rawValue) conf=\(String(format: "%.2f", queryIntent.confidence)) terms=\(queryIntent.extractedTerms.prefix(5).joined(separator: ",")) symbols=\(queryIntent.symbolHints.prefix(3).joined(separator: ","))"
        ))

        // =====================================================================
        // Stage 1b: Query Planner (DeepSeek, conditional on specificity)
        // =====================================================================
        let specificityAnalyzer = QuerySpecificityAnalyzer()
        let specificity = specificityAnalyzer.analyze(queryIntent: queryIntent, queryLength: query.count)
        var plannerHints: ValidatedPlannerHints? = nil
        var plannerMeta: PlannerMetadata

        if let dsConfig = deepSeekConfig, dsConfig.isConfigured, specificity.shouldRunPlanner {
            progress("PADA+: running query planner (specificity \(String(format: "%.2f", specificity.score)))...")
            let plannerStart = CFAbsoluteTimeGetCurrent()

            let plannerCache = PlannerCache(repoRoot: repoRoot)
            var plannerCacheHit = false

            // Check planner cache first
            if let cached = plannerCache.lookup(query: query, repoHash: meta.repoHash) {
                // Reconstruct minimal hints from cache
                plannerHints = ValidatedPlannerHints(
                    rewrittenQuery: cached.rewrittenQuery,
                    additionalTerms: cached.additionalTerms,
                    validatedFiles: cached.validatedFilePaths.map { ($0, "", 3.0) },
                    validatedDirs: cached.validatedDirPaths.map { ($0, "", 2.0) },
                    validatedSymbols: cached.validatedSymbols.map { ($0, "") },
                    governingFileRequests: cached.governingFilePaths.map { ($0, "", 5.0) },
                    dossierSubquestions: cached.dossierSubquestions,
                    coverageExpectations: cached.coverageExpectations,
                    invalidSuggestions: [],
                    plannerReason: cached.plannerReason
                )
                plannerCacheHit = true

                plannerMeta = PlannerMetadata(
                    plannerRan: true, plannerSkipReason: nil,
                    specificityScore: specificity.score,
                    rewrittenQuery: cached.rewrittenQuery,
                    validatedFileCount: cached.validatedFilePaths.count,
                    validatedDirCount: cached.validatedDirPaths.count,
                    validatedSymbolCount: cached.validatedSymbols.count,
                    governingFileRequestCount: cached.governingFilePaths.count,
                    invalidSuggestionCount: 0,
                    dossierSubquestions: cached.dossierSubquestions,
                    plannerCacheHit: true, plannerError: nil,
                    plannerReason: cached.plannerReason
                )
            } else {
                // Run early governing detection for planner input context
                let earlyGov = governingDetector.detect(candidates: [:], store: store, queryType: queryIntent.primary)

                let plannerInput = QueryPlannerService.buildPlannerInput(
                    query: query,
                    queryIntent: queryIntent,
                    specificity: specificity,
                    store: store,
                    meta: meta,
                    governingCandidates: earlyGov
                )

                let (output, _, plannerError) = await QueryPlannerService.callPlanner(
                    plannerInput: plannerInput,
                    configuration: dsConfig
                )

                if let output = output {
                    let validated = QueryPlannerService.validate(output: output, store: store, queryIntent: queryIntent)
                    plannerHints = validated

                    // Cache the validated result
                    plannerCache.store(hints: validated, query: query, repoHash: meta.repoHash)

                    plannerMeta = PlannerMetadata(
                        plannerRan: true, plannerSkipReason: nil,
                        specificityScore: specificity.score,
                        rewrittenQuery: validated.rewrittenQuery,
                        validatedFileCount: validated.validatedFiles.count,
                        validatedDirCount: validated.validatedDirs.count,
                        validatedSymbolCount: validated.validatedSymbols.count,
                        governingFileRequestCount: validated.governingFileRequests.count,
                        invalidSuggestionCount: validated.invalidSuggestions.count,
                        dossierSubquestions: validated.dossierSubquestions,
                        plannerCacheHit: false, plannerError: nil,
                        plannerReason: validated.plannerReason
                    )
                } else {
                    plannerMeta = PlannerMetadata(
                        plannerRan: true, plannerSkipReason: nil,
                        specificityScore: specificity.score,
                        rewrittenQuery: nil,
                        validatedFileCount: 0, validatedDirCount: 0,
                        validatedSymbolCount: 0, governingFileRequestCount: 0,
                        invalidSuggestionCount: 0, dossierSubquestions: [],
                        plannerCacheHit: false, plannerError: plannerError,
                        plannerReason: nil
                    )
                }
            }

            let plannerElapsed = Int((CFAbsoluteTimeGetCurrent() - plannerStart) * 1000)
            let hintsDesc: String
            if let h = plannerHints {
                hintsDesc = "files=\(h.validatedFiles.count) dirs=\(h.validatedDirs.count) syms=\(h.validatedSymbols.count) gov=\(h.governingFileRequests.count) invalid=\(h.invalidSuggestions.count) cache=\(plannerCacheHit)"
            } else {
                hintsDesc = "planner failed"
            }
            stages.append(StageLog(
                name: "query_planner",
                candidatesIn: 0, candidatesOut: 0,
                tokensUsed: plannerCacheHit ? 0 : 800,  // estimated planner tokens
                durationMs: plannerElapsed,
                notes: "specificity=\(String(format: "%.2f", specificity.score)) \(hintsDesc)"
            ))
        } else {
            let skipReason: String
            if deepSeekConfig == nil || !(deepSeekConfig?.isConfigured ?? false) {
                skipReason = "DeepSeek not configured"
            } else {
                skipReason = "high specificity (\(String(format: "%.2f", specificity.score)))"
            }
            plannerMeta = PlannerMetadata(
                plannerRan: false, plannerSkipReason: skipReason,
                specificityScore: specificity.score, rewrittenQuery: nil,
                validatedFileCount: 0, validatedDirCount: 0,
                validatedSymbolCount: 0, governingFileRequestCount: 0,
                invalidSuggestionCount: 0, dossierSubquestions: [],
                plannerCacheHit: false, plannerError: nil, plannerReason: nil
            )

            stages.append(StageLog(
                name: "query_planner",
                candidatesIn: 0, candidatesOut: 0,
                tokensUsed: 0, durationMs: 0,
                notes: "skipped: \(skipReason)"
            ))
        }

        // =====================================================================
        // Stage 2: Deterministic Candidate Discovery (FTS + graph + roles)
        // =====================================================================
        progress("PADA+: discovering candidates (deterministic)...")
        let stage2Start = CFAbsoluteTimeGetCurrent()

        var candidates: [String: PADACandidate] = [:]  // keyed by path

        // 2-pre: Apply planner hints — add planner-requested files and boost terms
        if let hints = plannerHints {
            // Add planner-requested files with boost
            for pf in hints.validatedFiles {
                if let file = store.file(byPath: pf.path) {
                    let prov = EvidenceProvenance(source: .plannerHint, trigger: "planner:file:\(pf.path)", hopDistance: 0, score: ValidatedPlannerHints.fileBoost)
                    addOrUpdate(&candidates, file: file, store: store, score: ValidatedPlannerHints.fileBoost, provenance: prov)
                }
            }

            // Add planner-requested governing files with higher boost
            for gf in hints.governingFileRequests {
                if let file = store.file(byPath: gf.path) {
                    let prov = EvidenceProvenance(source: .plannerHint, trigger: "planner:gov:\(gf.path)", hopDistance: 0, score: ValidatedPlannerHints.governingBoost)
                    addOrUpdate(&candidates, file: file, store: store, score: ValidatedPlannerHints.governingBoost, provenance: prov)
                }
            }

            // Planner-requested directory boost: search for files in those dirs
            for pd in hints.validatedDirs {
                let dirFiles = store.searchFiles(query: pd.path, limit: 10)
                for match in dirFiles {
                    guard let file = store.file(byId: match.rowid) else { continue }
                    if file.corpusTier == "binaryOrIgnored" || file.corpusTier == "externalDependency" { continue }
                    let prov = EvidenceProvenance(source: .plannerHint, trigger: "planner:dir:\(pd.path)", hopDistance: 0, score: ValidatedPlannerHints.dirBoost)
                    addOrUpdate(&candidates, file: file, store: store, score: ValidatedPlannerHints.dirBoost, provenance: prov)
                }
            }
        }

        // Merge planner additional terms with original query terms for FTS
        let effectiveTerms: [String]
        if let hints = plannerHints, !hints.additionalTerms.isEmpty {
            effectiveTerms = queryIntent.extractedTerms + hints.additionalTerms
        } else {
            effectiveTerms = queryIntent.extractedTerms
        }

        // Merge planner symbols with original symbol hints
        let effectiveSymbolHints: [String]
        if let hints = plannerHints, !hints.validatedSymbols.isEmpty {
            let original = Set(queryIntent.symbolHints)
            let plannerSyms = hints.validatedSymbols.map(\.symbol).filter { !original.contains($0) }
            effectiveSymbolHints = queryIntent.symbolHints + plannerSyms
        } else {
            effectiveSymbolHints = queryIntent.symbolHints
        }

        // 2a: FTS path/name matches for each query term (includes planner terms)
        for term in effectiveTerms {
            let fileMatches = store.searchFiles(query: term, limit: 30)
            for match in fileMatches {
                guard let file = store.file(byId: match.rowid) else { continue }
                if file.corpusTier == "binaryOrIgnored" { continue }
                if file.corpusTier == "externalDependency" { continue }
                if !queryPolicy.preferredTiers.isEmpty && !queryPolicy.preferredTiers.contains(file.corpusTier) { continue }

                let prov = EvidenceProvenance(source: .ftsPath, trigger: term, hopDistance: 0, score: 3.0)
                addOrUpdate(&candidates, file: file, store: store, score: 3.0, provenance: prov)
            }
        }

        // 2b: FTS segment content matches (includes planner terms)
        for term in effectiveTerms {
            let segMatches = store.searchSegments(query: term, limit: 40)
            for match in segMatches {
                guard let seg = store.segment(byId: match.rowid) else { continue }
                guard let file = store.file(byId: seg.fileId) else { continue }
                if file.corpusTier == "binaryOrIgnored" || file.corpusTier == "externalDependency" { continue }

                let prov = EvidenceProvenance(source: .ftsContent, trigger: term, hopDistance: 0, score: 2.5)
                addOrUpdate(&candidates, file: file, store: store, score: 2.5, provenance: prov)
            }
        }

        // 2c: FTS symbol matches (includes planner symbols)
        let symbolSearchTerms = effectiveSymbolHints + effectiveTerms
        for term in Set(symbolSearchTerms) {
            let symMatches = store.searchSymbols(query: term, limit: 20)
            for match in symMatches {
                guard let fileId = store.fileIdForSymbol(symbolId: match.rowid) else { continue }
                guard let file = store.file(byId: fileId) else { continue }
                if file.corpusTier == "binaryOrIgnored" || file.corpusTier == "externalDependency" { continue }

                let symbolScore: Double = queryIntent.symbolHints.contains(term) ? 5.0 : 3.5
                let prov = EvidenceProvenance(source: .ftsSymbol, trigger: term, hopDistance: 0, score: symbolScore)
                addOrUpdate(&candidates, file: file, store: store, score: symbolScore, provenance: prov)
            }
        }

        // 2d: Structural role files (entrypoints, manifests, configs)
        if queryPolicy.preferredFileTypes.contains("entrypoint") {
            let entrypoints = store.filesByType("entrypoint").prefix(5)
            for file in entrypoints {
                if file.corpusTier == "externalDependency" { continue }
                let prov = EvidenceProvenance(source: .structuralRole, trigger: "entrypoint", hopDistance: 0, score: 2.0)
                addOrUpdate(&candidates, file: file, store: store, score: 2.0, provenance: prov)
            }
        }

        if queryPolicy.preferredFileTypes.contains("config") {
            let configs = store.filesByType("config").prefix(8)
            for file in configs {
                if file.corpusTier == "externalDependency" || file.corpusTier == "generatedArtifact" { continue }
                let configScore: Double = file.roleTags.contains("manifest") ? 2.0 : 1.0
                let prov = EvidenceProvenance(source: .structuralRole, trigger: file.roleTags.contains("manifest") ? "manifest" : "config", hopDistance: 0, score: configScore)
                addOrUpdate(&candidates, file: file, store: store, score: configScore, provenance: prov)
            }
        }

        if queryPolicy.includeDocs {
            let docs = store.filesByType("docs").prefix(10)
            for file in docs {
                let prov = EvidenceProvenance(source: .structuralRole, trigger: "docs", hopDistance: 0, score: 1.5)
                addOrUpdate(&candidates, file: file, store: store, score: 1.5, provenance: prov)
            }
        }

        if queryPolicy.includeTests {
            let tests = store.filesByType("test").prefix(10)
            for file in tests {
                let prov = EvidenceProvenance(source: .structuralRole, trigger: "test", hopDistance: 0, score: 1.0)
                addOrUpdate(&candidates, file: file, store: store, score: 1.0, provenance: prov)
            }
        }

        // 2e: Seed files from initial retrieval
        if let retrieval = initialRetrieval {
            for item in retrieval.items {
                if let file = store.file(byPath: item.filePath) {
                    let prov = EvidenceProvenance(source: .seedRetrieval, trigger: "retrieval_seed", hopDistance: 0, score: item.score)
                    addOrUpdate(&candidates, file: file, store: store, score: item.score * 0.5, provenance: prov)
                }
            }
        }

        let deterministicCandidateCount = candidates.count

        stages.append(StageLog(
            name: "deterministic_discovery",
            candidatesIn: totalFirstPartyFiles,
            candidatesOut: deterministicCandidateCount,
            tokensUsed: 0,
            durationMs: Int((CFAbsoluteTimeGetCurrent() - stage2Start) * 1000),
            notes: "\(deterministicCandidateCount) candidates via FTS+graph+roles"
        ))

        // =====================================================================
        // Stage 3: LLM-Guided Candidate Screening (only if candidate set is large)
        // =====================================================================
        var clusterSummaries: [ClusterSummary] = []
        var modelExpansionHints: [String] = []

        if candidates.count > queryPolicy.maxFiles {
            progress("PADA+: screening \(candidates.count) candidates via LLM...")
            let stage3Start = CFAbsoluteTimeGetCurrent()
            var stage3Tokens = 0

            // Build compact manifests for screening
            let manifests: [FileManifestEntry] = candidates.values
                .sorted(by: { $0.score > $1.score })
                .prefix(configuration.maxCandidates)
                .map { candidate in
                    let syms = store.symbols(forFileId: candidate.fileId)
                    return FileManifestEntry(
                        path: candidate.path,
                        language: candidate.language,
                        lineCount: candidate.lineCount,
                        importance: candidate.importance,
                        tier: candidate.tier,
                        fileType: candidate.fileType,
                        summary: String(candidate.summary.prefix(200)),
                        roleTags: candidate.roleTags,
                        symbols: syms.prefix(8).map(\.name)
                    )
                }

            let batchSize = max(50, manifests.count / max(1, configuration.maxBatches))
            let batches = stride(from: 0, to: manifests.count, by: batchSize).map { start in
                Array(manifests[start..<min(start + batchSize, manifests.count)])
            }

            for (batchIdx, batch) in batches.prefix(configuration.maxBatches).enumerated() {
                progress("PADA+: screening batch \(batchIdx + 1)/\(min(batches.count, configuration.maxBatches))...")

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard let data = try? encoder.encode(batch),
                      let batchJSON = String(data: data, encoding: .utf8) else { continue }

                do {
                    let (result, model, fallback) = try await service.requestWithFallback(
                        systemPrompt: Prompts.screeningSystem(queryType: queryIntent.primary),
                        userPrompt: Prompts.screeningUser(
                            query: query,
                            queryType: queryIntent.primary,
                            terms: queryIntent.extractedTerms,
                            batchJSON: batchJSON
                        ),
                        configuration: configuration,
                        maxTokens: 2048,
                        as: ScreeningResponse.self
                    )
                    usedModel = model
                    usedFallback = fallback

                    // Boost model-selected paths
                    for sp in result.selectedPaths {
                        if var c = candidates[sp.path] {
                            let prov = EvidenceProvenance(source: .modelScreening, trigger: sp.reason, hopDistance: 0, score: sp.priority * 2.0)
                            c.score += sp.priority * 2.0
                            c.provenance.append(prov)
                            candidates[sp.path] = c
                        }
                    }

                    clusterSummaries.append(contentsOf: result.clusterSummaries)
                    modelExpansionHints.append(contentsOf: result.suggestedExpansions)

                    let batchTokens = batchJSON.estimatedTokenCount + 600
                    stage3Tokens += batchTokens
                } catch {
                    progress("PADA+: screening batch \(batchIdx + 1) failed — \(error.localizedDescription)")
                }
            }

            totalBuilderTokens += stage3Tokens
            stages.append(StageLog(
                name: "model_screening",
                candidatesIn: manifests.count,
                candidatesOut: candidates.count,
                tokensUsed: stage3Tokens,
                durationMs: Int((CFAbsoluteTimeGetCurrent() - stage3Start) * 1000),
                notes: "\(batches.count) batches, \(clusterSummaries.count) clusters, \(modelExpansionHints.count) expansion hints"
            ))
        } else {
            stages.append(StageLog(
                name: "model_screening",
                candidatesIn: candidates.count,
                candidatesOut: candidates.count,
                tokensUsed: 0,
                durationMs: 0,
                notes: "skipped (\(candidates.count) ≤ \(queryPolicy.maxFiles) files)"
            ))
        }

        // =====================================================================
        // Stage 4: Query-Type-Aware Graph Expansion (deterministic)
        // =====================================================================
        progress("PADA+: expanding via graph (policy: \(queryPolicy.graphHops) hops)...")
        let stage4Start = CFAbsoluteTimeGetCurrent()

        let preExpansionCount = candidates.count

        // Sort by score to expand from highest-value candidates
        let topCandidates = candidates.values.sorted { $0.score > $1.score }

        // Import graph expansion
        let expansionFrontierSize = min(topCandidates.count, queryPolicy.maxFiles)
        for hop in 0..<queryPolicy.graphHops {
            let frontier = hop == 0
                ? Array(topCandidates.prefix(expansionFrontierSize))
                : candidates.values.sorted { $0.score > $1.score }.filter { c in
                    c.provenance.contains { $0.hopDistance == hop - 1 }
                }.prefix(8).map { $0 }

            for candidate in frontier {
                // Follow imports
                let importers = store.filesImporting(fileId: candidate.fileId)
                for impId in importers.prefix(4) {
                    guard let file = store.file(byId: impId) else { continue }
                    if file.corpusTier == "externalDependency" || file.corpusTier == "binaryOrIgnored" { continue }
                    if candidates[file.relativePath] != nil { continue }

                    let prov = EvidenceProvenance(source: .graphImport, trigger: candidate.path, hopDistance: hop + 1, score: 1.5)
                    addOrUpdate(&candidates, file: file, store: store, score: 1.5, provenance: prov)
                }

                let imported = store.filesImportedBy(fileId: candidate.fileId)
                for depId in imported.prefix(4) {
                    guard let file = store.file(byId: depId) else { continue }
                    if file.corpusTier == "externalDependency" || file.corpusTier == "binaryOrIgnored" { continue }
                    if candidates[file.relativePath] != nil { continue }

                    let prov = EvidenceProvenance(source: .graphImport, trigger: candidate.path, hopDistance: hop + 1, score: 1.2)
                    addOrUpdate(&candidates, file: file, store: store, score: 1.2, provenance: prov)
                }

                // Same-directory neighbors (for architecture/whole-system queries)
                if queryPolicy.queryType == .architecture || queryPolicy.queryType == .wholeSystem {
                    let neighbors = store.filesInSameDirectory(fileId: candidate.fileId, limit: 3)
                    for nId in neighbors {
                        guard let file = store.file(byId: nId) else { continue }
                        if candidates[file.relativePath] != nil { continue }

                        let prov = EvidenceProvenance(source: .graphDirectory, trigger: candidate.path, hopDistance: hop + 1, score: 0.8)
                        addOrUpdate(&candidates, file: file, store: store, score: 0.8, provenance: prov)
                    }
                }
            }
        }

        // Symbol reference traversal (for implementation/debugging queries)
        if queryPolicy.symbolTraversalDepth > 0 {
            for symbol in queryIntent.symbolHints {
                // Find files that reference this symbol
                let refs = store.referencesToSymbol(name: symbol)
                for ref in refs.prefix(8) {
                    guard let file = store.file(byId: ref.sourceFileId) else { continue }
                    if file.corpusTier == "externalDependency" || file.corpusTier == "binaryOrIgnored" { continue }
                    if candidates[file.relativePath] != nil { continue }

                    let prov = EvidenceProvenance(source: .graphReference, trigger: symbol, hopDistance: 1, score: 2.0)
                    addOrUpdate(&candidates, file: file, store: store, score: 2.0, provenance: prov)
                }
            }
        }

        // Model expansion hints (from screening stage)
        for hint in Set(modelExpansionHints).prefix(15) {
            let fileMatches = store.searchFiles(query: hint, limit: 8)
            for match in fileMatches {
                guard let file = store.file(byId: match.rowid) else { continue }
                if file.corpusTier == "externalDependency" || file.corpusTier == "binaryOrIgnored" { continue }
                if candidates[file.relativePath] != nil { continue }

                let prov = EvidenceProvenance(source: .modelExpansion, trigger: hint, hopDistance: 1, score: 1.0)
                addOrUpdate(&candidates, file: file, store: store, score: 1.0, provenance: prov)
            }
        }

        let graphAdditions = candidates.count - preExpansionCount
        stages.append(StageLog(
            name: "graph_expansion",
            candidatesIn: preExpansionCount,
            candidatesOut: candidates.count,
            tokensUsed: 0,
            durationMs: Int((CFAbsoluteTimeGetCurrent() - stage4Start) * 1000),
            notes: "\(graphAdditions) added via graph (\(queryPolicy.graphHops) hops, symDepth=\(queryPolicy.symbolTraversalDepth))"
        ))

        // =====================================================================
        // Stage 4b: Doc↔Code Linking (deterministic)
        // =====================================================================
        let stage4bStart = CFAbsoluteTimeGetCurrent()
        let docLinks = docLinker.findLinks(candidates: candidates, store: store)
        docLinker.applyLinkBoosts(candidates: &candidates, links: docLinks)

        stages.append(StageLog(
            name: "doc_code_linking",
            candidatesIn: candidates.count,
            candidatesOut: candidates.count,
            tokensUsed: 0,
            durationMs: Int((CFAbsoluteTimeGetCurrent() - stage4bStart) * 1000),
            notes: "\(docLinks.count) doc↔code links found"
        ))

        // =====================================================================
        // Stage 4c: Governing File Detection (deterministic)
        // =====================================================================
        let stage4cStart = CFAbsoluteTimeGetCurrent()
        let governingFiles = governingDetector.detect(
            candidates: candidates,
            store: store,
            queryType: queryIntent.primary
        )

        // Ensure governing files are in the candidate set with boosted scores
        for gf in governingFiles {
            if let file = store.file(byId: gf.fileId) {
                let prov = EvidenceProvenance(source: .governing, trigger: gf.reason, hopDistance: 0, score: gf.priority)
                addOrUpdate(&candidates, file: file, store: store, score: gf.priority, provenance: prov)
            }
        }

        stages.append(StageLog(
            name: "governing_detection",
            candidatesIn: candidates.count,
            candidatesOut: candidates.count,
            tokensUsed: 0,
            durationMs: Int((CFAbsoluteTimeGetCurrent() - stage4cStart) * 1000),
            notes: "\(governingFiles.count) governing files detected: \(governingFiles.prefix(5).map { $0.governingType.rawValue + ":" + (($0.path as NSString).lastPathComponent) }.joined(separator: ", "))"
        ))

        // =====================================================================
        // Cache check: before expensive anchor selection, check dossier cache
        // =====================================================================
        let candidateFingerprint = DossierCache.candidateFingerprint(from: candidates)
        if let cached = dossierCache.lookup(query: query, repoHash: meta.repoHash, candidateFingerprint: candidateFingerprint, queryPolicy: queryPolicy) {
            progress("PADA+: cache hit — returning cached dossier")
            return cached.dossier
        }

        // =====================================================================
        // Stage 5: DETERMINISTIC ANCHOR SELECTION (NO LLM for evidence selection)
        // =====================================================================
        // The model NEVER invents new evidence. All evidence spans are selected
        // deterministically from the segment graph. The model is only used for
        // optional implementation path summarization if anchors are sparse.
        progress("PADA+: selecting anchors (deterministic)...")
        let stage5Start = CFAbsoluteTimeGetCurrent()

        let anchorResult = anchorSelector.selectAnchors(
            candidates: candidates,
            queryIntent: queryIntent,
            queryPolicy: queryPolicy,
            store: store,
            passport: meta.passport,
            governingFiles: governingFiles
        )

        // Count total segments examined
        let rankedCandidates = candidates.values.sorted { $0.score > $1.score }
        var totalSegmentsExamined = 0
        for candidate in rankedCandidates.prefix(queryPolicy.maxFiles) {
            totalSegmentsExamined += store.segments(forFileId: candidate.fileId).count
        }

        let allExtractedEvidence = anchorResult.exactEvidence
        let allSupportingContext = anchorResult.supportingContext
        var allMissingEvidence: [MissingEvidence] = []
        let implPath = anchorResult.implementationPath

        let stats = anchorResult.anchorStats
        stages.append(StageLog(
            name: "deterministic_anchors",
            candidatesIn: candidates.count,
            candidatesOut: allExtractedEvidence.count,
            tokensUsed: 0,
            durationMs: Int((CFAbsoluteTimeGetCurrent() - stage5Start) * 1000),
            notes: "gov=\(stats.governingAnchors) sym=\(stats.symbolAnchors) content=\(stats.contentAnchors) ref=\(stats.referenceAnchors) doc=\(stats.docAnchors) test=\(stats.testAnchors) ~\(stats.totalTokens)tok dropped=\(stats.droppedForBudget)"
        ))

        // =====================================================================
        // Stage 6: Structural Coverage Computation + Dossier Assembly
        // =====================================================================
        progress("PADA+: computing coverage + assembling dossier...")

        // Build must-read files with provenance
        let mustRead = rankedCandidates.prefix(min(80, queryPolicy.maxFiles)).map { candidate in
            MustReadFile(
                path: candidate.path,
                role: candidate.fileType,
                priority: candidate.score,
                why: candidate.provenance.map { "\($0.source.rawValue):\($0.trigger)" }.prefix(3).joined(separator: ", "),
                provenance: candidate.provenance
            )
        }

        // Evidence already has provenance from deterministic anchor selection
        let provenancedEvidence = allExtractedEvidence

        // Compute structural coverage report
        let coverageReport = computeCoverage(
            queryTerms: queryIntent.extractedTerms,
            symbolHints: queryIntent.symbolHints,
            candidates: candidates,
            evidencePaths: Set(provenancedEvidence.map(\.path)),
            store: store,
            totalFirstPartyFiles: totalFirstPartyFiles,
            queryPolicy: queryPolicy
        )

        // Compute confidence from structural conditions
        let structuralConfidence = computeStructuralConfidence(
            coverage: coverageReport,
            queryIntent: queryIntent,
            evidenceCount: provenancedEvidence.count,
            candidateCount: candidates.count
        )

        // Dropped candidates
        let droppedCandidates = rankedCandidates.dropFirst(queryPolicy.maxFiles).prefix(40).map { c in
            DroppedCandidate(path: c.path, reason: c.score < 1.0 ? "low_relevance" : "token_budget")
        }

        // Repo frame
        let subtreeSummariesRaw = store.allSubtreeSummaries()
        let relevantSubtrees = subtreeSummariesRaw.prefix(15).map { entry in
            RelevantSubtree(
                path: entry.root.isEmpty ? "(root)" : entry.root,
                whyRelevant: String(entry.summary.prefix(300)),
                priority: clusterSummaries.first(where: { $0.subtree == entry.root })?.relevance ?? 0.5
            )
        }
        let repoFrame = RepoFrame(
            oneSentenceIdentity: String(meta.passport.prefix(200)),
            relevantSubtrees: relevantSubtrees
        )

        // implPath already set from deterministic anchor selection

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        // Token estimate
        let evidenceTokens = provenancedEvidence.reduce(0) { $0 + $1.excerpt.estimatedTokenCount + 40 }
        let supportTokens = allSupportingContext.reduce(0) { $0 + $1.excerpt.estimatedTokenCount + 30 }
        let pathTokens = implPath.steps.reduce(0) { $0 + $1.whyItMatters.estimatedTokenCount + 30 }
        let dossierTokenEstimate = evidenceTokens + supportTokens + pathTokens + 500

        let diagnostics = BuilderDiagnostics(
            totalCandidatesConsidered: deterministicCandidateCount,
            totalSegmentsExamined: totalSegmentsExamined,
            passesRun: stages.count,
            totalBuilderTokensUsed: totalBuilderTokens,
            dossierTokenEstimate: dossierTokenEstimate,
            elapsedMs: elapsedMs,
            stages: stages,
            usedModel: usedModel,
            fallbackUsed: usedFallback,
            queryPolicy: queryPolicy
        )

        // Referenced-but-unanchored repair: flag governing files with no anchored evidence
        let anchoredPaths = Set(provenancedEvidence.map(\.path))
        for gf in governingFiles {
            if !anchoredPaths.contains(gf.path) {
                allMissingEvidence.append(MissingEvidence(
                    pathOrArea: gf.path,
                    reason: "Governing file (\(gf.governingType.rawValue)) detected but no evidence anchored — may indicate indexing gap",
                    severity: "high"
                ))
            }
        }

        // Also flag mustRead files that have no anchored evidence
        for mrf in mustRead.prefix(10) {
            if mrf.priority >= 5.0 && !anchoredPaths.contains(mrf.path) {
                let isGoverning = governingFiles.contains { $0.path == mrf.path }
                if !isGoverning {  // governing files already flagged above
                    allMissingEvidence.append(MissingEvidence(
                        pathOrArea: mrf.path,
                        reason: "High-priority file (score \(String(format: "%.1f", mrf.priority))) referenced but no evidence anchored",
                        severity: "medium"
                    ))
                }
            }
        }

        // Build governing file info for dossier
        let governingFileInfos = governingFiles.map { gf -> GoverningFileInfo in
            let anchoredCount = provenancedEvidence.filter { $0.path == gf.path }.count
            return GoverningFileInfo(
                path: gf.path,
                governingType: gf.governingType.rawValue,
                priority: gf.priority,
                reason: gf.reason,
                anchored: anchoredCount > 0,
                anchoredSegments: anchoredCount
            )
        }

        // Merge LLM-identified missing evidence with structural gaps
        var mergedMissing = allMissingEvidence
        for gap in coverageReport.gaps {
            let severity: String
            switch gap.gapType {
            case .noFTSHit, .symbolNotResolved:
                severity = "high"
            case .importNotFollowed, .noTestCoverage:
                severity = "medium"
            default:
                severity = "low"
            }
            mergedMissing.append(MissingEvidence(
                pathOrArea: gap.area,
                reason: "[\(gap.gapType.rawValue)] \(gap.description)",
                severity: severity
            ))
        }

        // Build complete file manifest — compact listing of ALL first-party files
        // Gives DeepSeek awareness of the entire repo (~20 tokens per file)
        let allFirstParty = store.firstPartyFiles(limit: 500)
        let evidencePathSet = Set(provenancedEvidence.map(\.path))
        let repoFileManifest = allFirstParty.map { file in
            RepoFileManifest(
                path: file.relativePath,
                fileType: file.fileType,
                lineCount: file.lineCount,
                summary: String(file.summary.prefix(120)),
                hasEvidence: evidencePathSet.contains(file.relativePath)
            )
        }

        let dossier = EvidenceDossier(
            queryIntent: queryIntent,
            queryPolicy: queryPolicy,
            repoFrame: repoFrame,
            implementationPath: implPath,
            mustReadFiles: mustRead,
            exactEvidence: provenancedEvidence,
            supportingContext: allSupportingContext,
            missingEvidence: mergedMissing,
            coverageReport: coverageReport,
            droppedCandidates: droppedCandidates,
            confidenceReport: structuralConfidence,
            builderDiagnostics: diagnostics,
            governingFiles: governingFileInfos,
            plannerMetadata: plannerMeta,
            repoFileManifest: repoFileManifest
        )

        // Store in dossier cache for future identical queries
        dossierCache.store(dossier: dossier, query: query, repoHash: meta.repoHash, candidateFingerprint: candidateFingerprint, queryPolicy: queryPolicy)

        progress("PADA+: dossier ready (\(provenancedEvidence.count) evidence, \(mustRead.count) files, \(coverageReport.gaps.count) gaps, ~\(dossierTokenEstimate) tokens)")
        return dossier
    }

    // MARK: - Candidate Management

    private func addOrUpdate(_ candidates: inout [String: PADACandidate], file: StoredFile, store: RepoMemoryStore, score: Double, provenance: EvidenceProvenance) {
        if var existing = candidates[file.relativePath] {
            existing.score += score
            existing.provenance.append(provenance)
            candidates[file.relativePath] = existing
        } else {
            candidates[file.relativePath] = PADACandidate(
                fileId: file.id,
                path: file.relativePath,
                score: score,
                provenance: [provenance],
                language: file.language,
                lineCount: file.lineCount,
                importance: file.importanceScore,
                tier: file.corpusTier,
                fileType: file.fileType,
                summary: file.summary,
                roleTags: file.roleTags
            )
        }
    }

    // MARK: - Structural Coverage Computation

    private func computeCoverage(
        queryTerms: [String],
        symbolHints: [String],
        candidates: [String: PADACandidate],
        evidencePaths: Set<String>,
        store: RepoMemoryStore,
        totalFirstPartyFiles: Int,
        queryPolicy: QueryPolicy
    ) -> CoverageReport {
        var gaps: [CoverageGap] = []

        // 1. Query term coverage: what fraction of terms had at least one FTS hit?
        var termsWithHits = 0
        for term in queryTerms {
            let hasFileHit = candidates.values.contains { c in
                c.provenance.contains { $0.source == .ftsPath && $0.trigger == term }
            }
            let hasContentHit = candidates.values.contains { c in
                c.provenance.contains { $0.source == .ftsContent && $0.trigger == term }
            }
            let hasSymbolHit = candidates.values.contains { c in
                c.provenance.contains { $0.source == .ftsSymbol && $0.trigger == term }
            }
            if hasFileHit || hasContentHit || hasSymbolHit {
                termsWithHits += 1
            } else {
                gaps.append(CoverageGap(
                    area: term,
                    gapType: .noFTSHit,
                    description: "No FTS match found for query term '\(term)'"
                ))
            }
        }
        let queryTermCoverage = queryTerms.isEmpty ? 1.0 : Double(termsWithHits) / Double(queryTerms.count)

        // 2. Symbol definition coverage: were symbol hints resolved to file definitions?
        var symbolsResolved = 0
        for symbol in symbolHints {
            let resolved = candidates.values.contains { c in
                c.provenance.contains { $0.source == .ftsSymbol && $0.trigger == symbol }
            }
            if resolved {
                symbolsResolved += 1
            } else {
                gaps.append(CoverageGap(
                    area: symbol,
                    gapType: .symbolNotResolved,
                    description: "Symbol '\(symbol)' not resolved to a definition"
                ))
            }
        }
        let symbolDefinitionCoverage = symbolHints.isEmpty ? 1.0 : Double(symbolsResolved) / Double(symbolHints.count)

        // 3. Import graph coverage: for evidence files, are their imports also in evidence?
        var importsFollowed = 0
        var importTotal = 0
        for path in evidencePaths {
            guard let candidate = candidates[path] else { continue }
            let imported = store.filesImportedBy(fileId: candidate.fileId)
            for depId in imported {
                guard let depFile = store.file(byId: depId) else { continue }
                if depFile.corpusTier == "externalDependency" || depFile.corpusTier == "binaryOrIgnored" { continue }
                importTotal += 1
                if evidencePaths.contains(depFile.relativePath) || candidates[depFile.relativePath] != nil {
                    importsFollowed += 1
                } else {
                    gaps.append(CoverageGap(
                        area: depFile.relativePath,
                        gapType: .importNotFollowed,
                        description: "Imported by \(path) but not in evidence set"
                    ))
                }
            }
        }
        let importGraphCoverage = importTotal == 0 ? 1.0 : Double(importsFollowed) / Double(importTotal)

        // 4. Test coverage gap
        if queryPolicy.includeTests || queryPolicy.queryType == .debugging {
            let hasTests = candidates.values.contains { $0.fileType == "test" }
            if !hasTests {
                gaps.append(CoverageGap(
                    area: "(test files)",
                    gapType: .noTestCoverage,
                    description: "No test files found in evidence set"
                ))
            }
        }

        // 5. Doc coverage gap (for architecture/whole-system)
        if queryPolicy.includeDocs {
            let hasDocs = candidates.values.contains { $0.fileType == "docs" }
            if !hasDocs {
                gaps.append(CoverageGap(
                    area: "(documentation)",
                    gapType: .noDocCoverage,
                    description: "No documentation files found in evidence set"
                ))
            }
        }

        // Limit gap list to most important ones
        let sortedGaps = gaps.sorted { a, b in
            let aPriority: Int
            switch a.gapType {
            case .symbolNotResolved: aPriority = 0
            case .noFTSHit: aPriority = 1
            case .importNotFollowed: aPriority = 2
            default: aPriority = 3
            }
            let bPriority: Int
            switch b.gapType {
            case .symbolNotResolved: bPriority = 0
            case .noFTSHit: bPriority = 1
            case .importNotFollowed: bPriority = 2
            default: bPriority = 3
            }
            return aPriority < bPriority
        }

        return CoverageReport(
            queryTermCoverage: queryTermCoverage,
            symbolDefinitionCoverage: symbolDefinitionCoverage,
            importGraphCoverage: importGraphCoverage,
            gaps: Array(sortedGaps.prefix(20)),
            totalFirstPartyFiles: totalFirstPartyFiles,
            filesExamined: candidates.count,
            filesIncluded: evidencePaths.count
        )
    }

    // MARK: - Structural Confidence Computation

    private func computeStructuralConfidence(
        coverage: CoverageReport,
        queryIntent: QueryIntent,
        evidenceCount: Int,
        candidateCount: Int
    ) -> ConfidenceReport {
        // Implementation coverage: based on symbol resolution + query term coverage
        let implCoverage: Double
        switch queryIntent.primary {
        case .implementation:
            implCoverage = (coverage.symbolDefinitionCoverage * 0.6 + coverage.queryTermCoverage * 0.4)
        case .debugging:
            implCoverage = (coverage.symbolDefinitionCoverage * 0.5 + coverage.queryTermCoverage * 0.3 + coverage.importGraphCoverage * 0.2)
        default:
            implCoverage = coverage.queryTermCoverage
        }

        // Doc coverage: based on whether docs were found when expected
        let docCov: Double
        if queryIntent.primary == .architecture || queryIntent.primary == .wholeSystem {
            let hasDocGap = coverage.gaps.contains { $0.gapType == .noDocCoverage }
            docCov = hasDocGap ? 0.3 : 0.8
        } else {
            docCov = 0.7  // docs less critical for impl/debug queries
        }

        // Execution path confidence: based on import graph coverage
        let pathConf = coverage.importGraphCoverage * 0.8 + (evidenceCount > 0 ? 0.2 : 0)

        // Overall: weighted combination
        let overall: Double
        switch queryIntent.primary {
        case .implementation:
            overall = implCoverage * 0.5 + pathConf * 0.3 + docCov * 0.1 + (coverage.queryTermCoverage > 0.7 ? 0.1 : 0)
        case .architecture, .wholeSystem:
            overall = docCov * 0.3 + coverage.queryTermCoverage * 0.3 + pathConf * 0.2 + (Double(candidateCount) / 50.0).clamped(to: 0...0.2)
        case .debugging:
            overall = implCoverage * 0.4 + pathConf * 0.4 + (coverage.gaps.contains { $0.gapType == .noTestCoverage } ? 0.0 : 0.2)
        case .mixed:
            overall = (implCoverage + docCov + pathConf) / 3.0
        }

        return ConfidenceReport(
            overall: min(1.0, overall),
            implementationCoverage: min(1.0, implCoverage),
            docCoverage: min(1.0, docCov),
            executionPathConfidence: min(1.0, pathConf)
        )
    }
}

// MARK: - Double clamped extension

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, self))
    }
}

// MARK: - Prompt Templates (LLM screening stage only)
// NOTE: Evidence extraction prompts were REMOVED in PADA+ 2.0.
// Stage 5 is now fully deterministic — the LLM never selects evidence spans.
// The only remaining LLM role is candidate SCREENING in Stage 3 (conditional).

private enum Prompts {

    // ---- Candidate Screening (query-type-aware) ----

    static func screeningSystem(queryType: QueryType) -> String {
        let typeGuidance: String
        switch queryType {
        case .implementation:
            typeGuidance = "Prioritize source code files containing the implementation. Look for functions, classes, and methods that match the query. Deprioritize docs and config unless they define wiring."
        case .architecture:
            typeGuidance = "Prioritize files that reveal structure: entry points, orchestrators, high-level modules, docs, and config. Include files from diverse subtrees to show breadth."
        case .debugging:
            typeGuidance = "Prioritize files along the likely failure path: error handlers, validators, the code path from entry to crash point. Include test files that might reproduce the issue."
        case .wholeSystem:
            typeGuidance = "Select a representative cross-section: entry points, key services, config, and docs. Aim for breadth over depth."
        case .mixed:
            typeGuidance = "Balance implementation detail with structural context. Include both code and documentation where relevant."
        }

        return """
        You are screening repository files for relevance to a developer question.
        \(typeGuidance)
        Return JSON only. No markdown, no commentary.
        Schema:
        {
          "selected_paths": [
            {"path": "...", "priority": 0.0-1.0, "role": "entrypoint|orchestrator|service|storage|api|ui|test|doc|config", "reason": "..."}
          ],
          "suggested_expansions": ["keywords or patterns to search for in other batches"],
          "cluster_summaries": [
            {"subtree": "path/prefix", "summary": "what this area does", "file_count": 0, "relevance": 0.0-1.0}
          ]
        }
        Be selective. Only include files with clear relevance.
        """
    }

    static func screeningUser(
        query: String,
        queryType: QueryType,
        terms: [String],
        batchJSON: String
    ) -> String {
        """
        QUESTION: \(query)
        QUERY TYPE: \(queryType.rawValue)
        KEY TERMS: \(terms.prefix(10).joined(separator: ", "))

        FILE BATCH:
        \(batchJSON)

        Select the most relevant files from this batch.
        """
    }
}
