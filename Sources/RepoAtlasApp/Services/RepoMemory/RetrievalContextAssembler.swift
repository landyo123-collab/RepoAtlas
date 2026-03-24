import Foundation

/// Assembles retrieval results into a bounded, high-signal, multi-resolution context pack for DeepSeek.
struct RetrievalContextAssembler {

    /// Build a full AIContext from retrieval results, ready for DeepSeek.
    func assemble(query: String, retrieval: RetrievalResult, repoDisplayName: String) -> AIContext {
        let slices = buildSlices(from: retrieval)
        let prompt = buildPrompt(query: query, retrieval: retrieval, repoDisplayName: repoDisplayName, slices: slices)
        let tokenEstimate = prompt.estimatedTokenCount
        let cacheKey = (repoDisplayName + query + slices.map { $0.filePath + $0.lineRange + $0.contentHash }.joined(separator: "|")).sha256Hex

        return AIContext(
            prompt: prompt,
            slices: slices,
            tokenEstimate: tokenEstimate,
            cacheKey: cacheKey
        )
    }

    /// Build ContextSlices from retrieval items (includes tier in reason for debug)
    private func buildSlices(from retrieval: RetrievalResult) -> [ContextSlice] {
        var slices: [ContextSlice] = []

        for item in retrieval.items {
            let tierNote = item.corpusTier == "firstParty" ? "" : " (\(item.corpusTier))"
            for seg in item.segments {
                let slice = ContextSlice(
                    filePath: item.filePath,
                    lineRange: "\(seg.startLine)-\(seg.endLine)",
                    reason: item.reason + tierNote,
                    tokenEstimate: seg.tokenEstimate,
                    contentHash: seg.content.sha256Hex,
                    text: seg.content
                )
                slices.append(slice)
            }
        }

        return slices
    }

    /// Build the full multi-resolution prompt for DeepSeek.
    /// Structure: passport → subtree orientation → provenance → session → precise evidence slices
    private func buildPrompt(query: String, retrieval: RetrievalResult, repoDisplayName: String, slices: [ContextSlice]) -> String {
        let passport = retrieval.passport

        // Multi-resolution layer: subtree/project summaries for orientation
        let subtreeBlock = buildSubtreeBlock(from: retrieval.relevantSubtreeSummaries)

        // Context slices block (precise evidence)
        let sliceBlock = slices.map { slice in
            """
            FILE: \(slice.filePath)
            LINES: \(slice.lineRange)
            REASON: \(slice.reason)
            ---
            \(slice.text)
            """
        }.joined(separator: "\n\n")

        // Provenance summary
        let fileCount = Set(retrieval.items.map(\.filePath)).count
        let segCount = slices.count
        let provenanceLine = "Retrieved \(segCount) segments from \(fileCount) files using: \(retrieval.seedSummary.prefix(200))"

        // Session context
        let sessionBlock = retrieval.sessionContext.isEmpty ? "" : """

        SESSION CONTEXT (previous questions about this repo):
        \(retrieval.sessionContext)
        """

        return """
        You are helping a developer understand a code repository.
        Be precise, cite file paths and line numbers when making claims.
        Answer thoroughly and confidently from the provided context.

        REPO PASSPORT:
        \(passport)
        \(subtreeBlock)
        QUESTION: \(query)

        RETRIEVAL: \(provenanceLine)
        \(sessionBlock)

        CONTEXT SLICES:
        \(sliceBlock)
        """
    }

    /// Build a subtree orientation block from relevant subtree summaries.
    /// This gives DeepSeek structural awareness before it sees individual code slices.
    private func buildSubtreeBlock(from summaries: [(root: String, summary: String)]) -> String {
        guard !summaries.isEmpty else { return "" }

        // Budget: at most 12 subtree summaries, each trimmed to ~400 chars
        let selected = summaries.prefix(12)
        let lines = selected.map { entry in
            let label = entry.root.isEmpty ? "(repo root)" : entry.root
            let trimmed = String(entry.summary.prefix(400))
            return "  \(label): \(trimmed)"
        }

        return """

        PROJECT STRUCTURE (relevant subtrees):
        \(lines.joined(separator: "\n"))

        """
    }

    // MARK: - Dossier-Aware Assembly

    /// Build a full AIContext from an evidence dossier, ready for DeepSeek.
    /// This produces a much stronger context than the standard retrieval path.
    func assembleFromDossier(query: String, dossier: EvidenceDossier, repoDisplayName: String) -> AIContext {
        let prompt = buildDossierPrompt(query: query, dossier: dossier, repoDisplayName: repoDisplayName)
        let slices = buildSlicesFromDossier(dossier: dossier)
        let tokenEstimate = prompt.estimatedTokenCount
        let cacheKey = (repoDisplayName + query + "dossier:" + dossier.exactEvidence.map { $0.path + $0.lineRange }.joined(separator: "|")).sha256Hex

        return AIContext(
            prompt: prompt,
            slices: slices,
            tokenEstimate: tokenEstimate,
            cacheKey: cacheKey
        )
    }

    /// Build ContextSlices from dossier evidence (for UI preview).
    private func buildSlicesFromDossier(dossier: EvidenceDossier) -> [ContextSlice] {
        var slices: [ContextSlice] = []

        for evidence in dossier.exactEvidence {
            slices.append(ContextSlice(
                filePath: evidence.path,
                lineRange: evidence.lineRange,
                reason: "evidence: \(evidence.why)",
                tokenEstimate: evidence.excerpt.estimatedTokenCount + 30,
                contentHash: evidence.excerpt.sha256Hex,
                text: evidence.excerpt
            ))
        }

        for ctx in dossier.supportingContext {
            slices.append(ContextSlice(
                filePath: ctx.path,
                lineRange: "",
                reason: "supporting: \(ctx.kind)",
                tokenEstimate: ctx.excerpt.estimatedTokenCount + 20,
                contentHash: ctx.excerpt.sha256Hex,
                text: ctx.excerpt
            ))
        }

        return slices
    }

    /// Build the DeepSeek prompt from an evidence dossier.
    private func buildDossierPrompt(query: String, dossier: EvidenceDossier, repoDisplayName: String) -> String {
        // Repo frame
        let repoFrame = """
        REPO: \(repoDisplayName)
        IDENTITY: \(dossier.repoFrame.oneSentenceIdentity)
        """

        // Relevant subtrees
        let subtreeLines = dossier.repoFrame.relevantSubtrees.prefix(12).map { st in
            "  \(st.path): \(st.whyRelevant)"
        }
        let subtreeBlock = subtreeLines.isEmpty ? "" : """

        RELEVANT SUBTREES:
        \(subtreeLines.joined(separator: "\n"))
        """

        // Implementation path
        let implPathBlock: String
        if dossier.implementationPath.steps.isEmpty {
            implPathBlock = ""
        } else {
            let steps = dossier.implementationPath.steps.map { step in
                "  \(step.order). [\(step.role)] \(step.path) → \(step.symbol): \(step.whyItMatters)"
            }.joined(separator: "\n")
            implPathBlock = """

            IMPLEMENTATION PATH:
            \(dossier.implementationPath.summary)
            \(steps)
            """
        }

        // Separate governing evidence from regular evidence
        let governingEvidence = dossier.exactEvidence.filter { ev in
            ev.provenance.contains { $0.source == .governing }
        }
        let regularEvidence = dossier.exactEvidence.filter { ev in
            !ev.provenance.contains { $0.source == .governing }
        }

        // Governing evidence block (truth-source docs — presented first for maximum authority)
        let governingBlock: String
        if governingEvidence.isEmpty {
            governingBlock = ""
        } else {
            let govLines = governingEvidence.map { ev in
                """
                FILE: \(ev.path)
                LINES: \(ev.lineRange)
                SYMBOL: \(ev.symbol)
                KIND: \(ev.kind)
                WHY: \(ev.why)
                ---
                \(ev.excerpt)
                """
            }.joined(separator: "\n\n")
            governingBlock = """

            GOVERNING EVIDENCE (truth-source documents — these define the repo's actual structure, status, and rules):
            \(govLines)

            """
        }

        // Regular exact evidence
        let evidenceBlock = regularEvidence.map { ev in
            """
            FILE: \(ev.path)
            LINES: \(ev.lineRange)
            SYMBOL: \(ev.symbol)
            KIND: \(ev.kind)
            WHY: \(ev.why)
            ---
            \(ev.excerpt)
            """
        }.joined(separator: "\n\n")

        // Supporting context
        let supportBlock = dossier.supportingContext.map { ctx in
            """
            SUPPORTING [\(ctx.kind)]: \(ctx.path)
            WHY: \(ctx.why)
            ---
            \(ctx.excerpt)
            """
        }.joined(separator: "\n\n")

        // Missing evidence
        let missingBlock: String
        if dossier.missingEvidence.isEmpty {
            missingBlock = ""
        } else {
            let lines = dossier.missingEvidence.map { me in
                "  [\(me.severity)] \(me.pathOrArea): \(me.reason)"
            }.joined(separator: "\n")
            missingBlock = """

            MISSING EVIDENCE:
            \(lines)
            """
        }

        // Confidence
        let conf = dossier.confidenceReport
        let confLine = "Confidence: overall=\(String(format: "%.1f", conf.overall)) impl=\(String(format: "%.1f", conf.implementationCoverage)) docs=\(String(format: "%.1f", conf.docCoverage)) path=\(String(format: "%.1f", conf.executionPathConfidence))"

        // Complete file manifest — compact listing of ALL first-party files
        let manifestBlock: String
        if dossier.repoFileManifest.isEmpty {
            manifestBlock = ""
        } else {
            let filesWithEvidence = dossier.repoFileManifest.filter(\.hasEvidence).count
            let manifestLines = dossier.repoFileManifest.map { entry in
                let marker = entry.hasEvidence ? "*" : " "
                let summaryText = entry.summary.isEmpty ? "" : " — \(entry.summary)"
                return "  \(marker) \(entry.path) [\(entry.fileType), \(entry.lineCount) lines]\(summaryText)"
            }
            manifestBlock = """

        COMPLETE FILE MANIFEST (\(dossier.repoFileManifest.count) first-party files, * = evidence included for \(filesWithEvidence)):
        \(manifestLines.joined(separator: "\n"))

        """
        }

        return """
        You are helping a developer understand a code repository.
        You have been given a comprehensive evidence dossier built by deep analysis of the entire repo.
        The dossier includes a COMPLETE FILE MANIFEST listing every file in the repo with summaries, plus detailed evidence slices from the most relevant files.
        You have full repo awareness. Answer thoroughly and confidently from what is provided.
        Be precise, cite file paths and line numbers when making claims.
        Do not add "missing context" notes — the manifest covers all files. Do not invent facts beyond what the evidence shows.

        \(repoFrame)
        \(subtreeBlock)

        QUESTION: \(query)
        QUERY INTENT: \(dossier.queryIntent.primary.rawValue)
        \(implPathBlock)

        \(confLine)
        COVERAGE: terms=\(String(format: "%.0f%%", dossier.coverageReport.queryTermCoverage * 100)) symbols=\(String(format: "%.0f%%", dossier.coverageReport.symbolDefinitionCoverage * 100)) imports=\(String(format: "%.0f%%", dossier.coverageReport.importGraphCoverage * 100)) (examined \(dossier.coverageReport.filesExamined)/\(dossier.coverageReport.totalFirstPartyFiles) files, included \(dossier.coverageReport.filesIncluded))
        \(manifestBlock)
        \(missingBlock)
        \(governingBlock)
        EXACT EVIDENCE:
        \(evidenceBlock)

        SUPPORTING CONTEXT:
        \(supportBlock)
        """
    }

    /// Build context for Launchpad (run planning) using repo memory
    func assembleForLaunchpad(repoRoot: String, repoDisplayName: String, languageCounts: [String: Int],
                               topFiles: [String], containers: [String]) -> RepoRunContext? {
        guard let store = try? RepoMemoryStore(repoRoot: repoRoot) else { return nil }
        guard let meta = store.repoMeta() else { return nil }

        let configFiles = store.filesByType("config")
        let entrypoints = store.filesByType("entrypoint")
        let topImportance = store.topFiles(limit: 10)

        var selected: [StoredFile] = []
        var seen: Set<String> = []

        func add(_ file: StoredFile) {
            guard !seen.contains(file.relativePath) else { return }
            selected.append(file)
            seen.insert(file.relativePath)
        }

        for f in configFiles where f.roleTags.contains("manifest") { add(f) }
        for f in configFiles.prefix(5) { add(f) }
        for f in entrypoints.prefix(3) { add(f) }
        for f in topImportance { add(f) }

        let fileLimit = 18
        let selectedFiles = Array(selected.prefix(fileLimit))

        var fileBlocks: [String] = []
        for file in selectedFiles {
            let segs = store.segments(forFileId: file.id)
            let content: String
            if segs.isEmpty {
                content = "(no content indexed)"
            } else {
                var lines = 0
                var text = ""
                for seg in segs {
                    let segLines = seg.endLine - seg.startLine + 1
                    if lines + segLines > 180 { break }
                    if !text.isEmpty { text += "\n" }
                    text += seg.content
                    lines += segLines
                }
                content = text
            }
            fileBlocks.append("""
            FILE: \(file.relativePath)
            ---
            \(content)
            """)
        }

        let topFilePaths = topFiles.prefix(10).joined(separator: ", ")
        let containerBlock = containers.isEmpty ? "(none found)" : containers.joined(separator: "\n")

        // Include subtree summaries for launchpad orientation
        let allSubtrees = store.allSubtreeSummaries()
        let subtreeLines = allSubtrees.prefix(5).map { entry in
            let label = entry.root.isEmpty ? "(root)" : entry.root
            return "  \(label): \(entry.fileCount) files — \(String(entry.summary.prefix(150)))"
        }
        let subtreeBlock = subtreeLines.isEmpty ? "" : """

        PROJECT SUBTREES:
        \(subtreeLines.joined(separator: "\n"))
        """

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

        REPO PASSPORT:
        \(meta.passport)
        \(subtreeBlock)
        REPO:
        - Name: \(repoDisplayName)
        - Languages: \(languageCounts.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        - Top files: \(topFilePaths)
        - Project containers:
        \(containerBlock)

        CONTEXT FILES:
        \(fileBlocks.joined(separator: "\n\n"))
        """

        return RepoRunContext(prompt: prompt, includedFiles: selectedFiles.map(\.relativePath))
    }
}
