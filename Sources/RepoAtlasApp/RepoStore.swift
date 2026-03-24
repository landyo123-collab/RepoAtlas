import Foundation
import SwiftUI
import AppKit

@MainActor
final class RepoStore: ObservableObject {
    @Published private(set) var repo: RepoModel?
    @Published var fileTree: [FileNode] = []
    @Published var selectedFilePath: String?
    @Published var isLoading = false
    @Published var statusMessage = "Drop a repository or use Open to get started."
    @Published var latestAnswer = ""
    @Published var latestQuestion = ""
    @Published var isAsking = false
    @Published var latestContextSlices: [ContextSlice] = []

    @Published var launchpadPlan: LaunchpadRunPlan?
    @Published var launchpadContextFiles: [String] = []
    @Published var isPlanningLaunchpad = false
    @Published var isRunningLaunchpad = false
    @Published var launchpadPlanningError: String?
    @Published var launchpadPlanningNotice: String?
    @Published var launchpadRunError: String?
    @Published var launchpadLogs: [String] = []
    @Published var launchpadLogLineCount = 0
    @Published var launchpadTerminalOutputExpanded = true
    @Published var launchpadPlannedPreviewURL: URL?
    @Published var launchpadLivePreviewURL: URL?
    @Published var launchpadWebStartupStatus: String?
    @Published var launchpadExitCode: Int32?
    @Published var launchpadLaunchedAppPath: String?
    @Published var launchpadExecutionCommandDisplay: String?
    @Published var launchpadResolvedExecutableMessage: String?
    @Published var launchpadEnvironmentMessage: String?
    @Published var launchpadSetupRequired = false
    @Published var launchpadBootstrapReason: String?
    @Published var launchpadBootstrapCommands: [String] = []
    @Published var isBootstrappingPythonEnvironment = false
    @Published var launchpadFailureClassificationMessage: String?
    @Published var launchpadPlannerRawResponse: String?
    @Published var launchpadNativeStrategy: String?
    @Published var launchpadNativeStatus: String?
    @Published var launchpadNativeBuildCommandDisplay: String?
    @Published var launchpadNativeBuildSucceeded: Bool?
    @Published var launchpadNativeLaunchTargetPath: String?
    @Published var launchpadNativeIsGUIApp = false

    // MARK: - Repo Memory State
    @Published var repoMemoryIndexed = false
    @Published var repoMemoryFileCount = 0
    @Published var repoMemoryIndexedAt: Date?
    @Published var repoMemoryStale = false
    @Published var isIndexingMemory = false
    @Published var memoryIndexProgress: String = ""
    @Published var memoryIndexFraction: Double = 0
    @Published var retrievalDebugSummary: String = ""
    @Published var embeddingCount: Int = 0
    @Published var embeddingsAvailable: Bool = false

    // MARK: - Evidence Builder State
    @Published var evidenceBuilderActive = false
    @Published var evidenceBuilderProgress: String = ""
    @Published var evidenceBuilderDiagnostics: String = ""
    @Published var latestDossier: EvidenceDossier?

    private let scanner = RepoScanner()
    private let analyzer = RepoAnalyzer()
    private let contextBuilder = AIContextBuilder()
    private let cache = AIContextCache()
    private let aiService = DeepSeekService()
    private let runContextBuilder = RepoRunContextBuilder()
    private let webRunDetector = WebRunDetector()
    private let runPlanner = DeepSeekRunPlanner()
    private let processRunner = ProcessRunner()
    private let executableResolver = ExecutableResolver()
    private let pythonBootstrapPlanner = PythonBootstrapPlanner()
    private let failureClassifier = LaunchFailureClassifier()
    private let webServerReadinessMonitor = WebServerReadinessMonitor()
    private let memoryBuilder = RepoMemoryBuilder()
    private let retriever = RepoRetriever()
    private let contextAssembler = RetrievalContextAssembler()
    private let evidenceBuilder = EvidenceBuilderOrchestrator()

    private var launchpadBootstrapPlanCommands: [BootstrapCommand] = []
    private var launchpadStopRequested = false
    private var launchpadWebReadinessTask: Task<Void, Never>?
    private var launchpadLogFlushTask: Task<Void, Never>?
    private var launchpadPendingLogFlush = false
    private var launchpadAllLogs: [String] = []
    private var launchpadDidAutoCollapseLogs = false
    private var launchpadNativeExecutableProcess: Process?
    private var launchpadLaunchedNativeProcessIdentifier: pid_t?

    private let launchpadLogLimit = 1_200
    private let launchpadAutoCollapseThreshold = 250
    private let launchpadLogFlushIntervalNanoseconds: UInt64 = 150_000_000

    private enum NativeLaunchStrategy: String {
        case xcodeWorkspace = "Xcode Workspace"
        case xcodeProject = "Xcode Project"
        case swiftPackage = "Swift Package"
        case unsupported = "Unsupported"
    }

    private struct SwiftGUICapabilityAssessment {
        let likelyGUI: Bool
        let signals: [String]
    }

    private enum NativeExecutableLaunchOutcome {
        case running(process: Process)
        case exited(code: Int32)
        case failed(message: String)
    }

    deinit {
        launchpadLogFlushTask?.cancel()
        launchpadWebReadinessTask?.cancel()
        processRunner.stop()
    }

    func setLaunchpadTerminalOutputExpanded(_ isExpanded: Bool) {
        launchpadTerminalOutputExpanded = isExpanded
        if isExpanded {
            flushLaunchpadLogsForUI(force: true)
        }
    }

    func importRepository(at url: URL, embeddingConfig: EmbeddingConfiguration = .disabled) {
        processRunner.stop()
        isLoading = true
        statusMessage = "Scanning \(url.lastPathComponent)..."
        latestAnswer = ""
        latestContextSlices = []
        resetLaunchpadState()
        repoMemoryIndexed = false
        repoMemoryStale = false
        isIndexingMemory = false
        embeddingCount = 0

        let embConfig = embeddingConfig
        Task.detached(priority: .userInitiated) { [scanner, analyzer, memoryBuilder, retriever] in
            do {
                let scanned = try scanner.scan(rootURL: url)
                let analyzed = analyzer.analyze(scan: scanned)
                let tree = FileNode.buildTree(from: analyzed.files)
                await MainActor.run {
                    self.repo = analyzed
                    self.fileTree = tree
                    self.selectedFilePath = analyzed.files.first?.relativePath
                    self.isLoading = false
                    self.statusMessage = "Scanned \(analyzed.summary.scannedTextFiles) text files in \(analyzed.displayName). Building repo memory..."
                    self.isIndexingMemory = true
                }

                // Check if existing index is fresh
                let indexFresh = retriever.isIndexFresh(repoRoot: analyzed.rootPath, currentHash: analyzed.repoHash)
                if indexFresh {
                    let status = retriever.indexStatus(repoRoot: analyzed.rootPath)
                    let freshEmbCount: Int
                    if let memStore = try? RepoMemoryStore(repoRoot: analyzed.rootPath) {
                        freshEmbCount = memStore.embeddingCount(targetType: "file_summary")
                    } else {
                        freshEmbCount = 0
                    }
                    await MainActor.run {
                        self.repoMemoryIndexed = true
                        self.repoMemoryFileCount = status.fileCount
                        self.repoMemoryIndexedAt = status.indexedAt
                        self.repoMemoryStale = false
                        self.isIndexingMemory = false
                        self.embeddingCount = freshEmbCount
                        self.embeddingsAvailable = embConfig.isAvailable
                        self.statusMessage = "Scanned \(analyzed.summary.scannedTextFiles) files. Repo memory is fresh (\(status.fileCount) files indexed)."
                    }
                    return
                }

                // Build new repo memory (with optional embeddings)
                try memoryBuilder.buildMemory(from: scanned, repo: analyzed, embeddingConfig: embConfig) { progress in
                    Task { @MainActor in
                        self.memoryIndexProgress = "\(progress.phase): \(progress.detail)"
                        self.memoryIndexFraction = progress.fraction
                    }
                }

                // Update embedding count
                let embCount: Int
                if let memStore = try? RepoMemoryStore(repoRoot: analyzed.rootPath) {
                    embCount = memStore.embeddingCount(targetType: "file_summary")
                } else {
                    embCount = 0
                }

                let status = retriever.indexStatus(repoRoot: analyzed.rootPath)
                await MainActor.run {
                    self.repoMemoryIndexed = true
                    self.repoMemoryFileCount = status.fileCount
                    self.repoMemoryIndexedAt = status.indexedAt
                    self.embeddingCount = embCount
                    self.embeddingsAvailable = embConfig.isAvailable
                    self.repoMemoryStale = false
                    self.isIndexingMemory = false
                    self.statusMessage = "Repo memory built: \(status.fileCount) files indexed with segments, symbols, and references."
                }

            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.isIndexingMemory = false
                    self.statusMessage = "Scan complete but memory build failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func rescanCurrentRepository(embeddingConfig: EmbeddingConfiguration = .disabled) {
        guard let repo else { return }
        importRepository(at: URL(fileURLWithPath: repo.rootPath), embeddingConfig: embeddingConfig)
    }

    /// Embed (or re-embed) file summaries for the current repo without a full rescan.
    func embedCurrentRepository(embeddingConfig: EmbeddingConfiguration) {
        guard let repo else { return }
        guard embeddingConfig.isAvailable else {
            statusMessage = "Embeddings not configured. Add an OpenAI API key in Settings."
            return
        }
        guard !isIndexingMemory else { return }

        isIndexingMemory = true
        statusMessage = "Embedding file summaries..."

        let rootPath = repo.rootPath
        let embConfig = embeddingConfig

        Task.detached(priority: .userInitiated) {
            let service = EmbeddingService()
            guard let store = try? RepoMemoryStore(repoRoot: rootPath) else {
                await MainActor.run {
                    self.isIndexingMemory = false
                    self.statusMessage = "No repo memory found. Scan first."
                }
                return
            }

            let files = store.firstPartyFiles(limit: 10_000)
            let batchSize = 64
            var embedded = 0

            for batchStart in stride(from: 0, to: files.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, files.count)
                let batch = Array(files[batchStart..<batchEnd])

                let items = batch.compactMap { file -> (id: Int64, text: String, hash: String)? in
                    guard !file.summary.isEmpty else { return nil }
                    let currentHash = file.summary.sha256Hex
                    // Skip if fresh embedding already exists
                    if let storedHash = store.embeddingContentHash(targetType: "file_summary", targetId: file.id),
                       storedHash == currentHash {
                        return nil
                    }
                    return (file.id, file.summary, currentHash)
                }

                guard !items.isEmpty else {
                    embedded += batch.count
                    continue
                }

                let texts = items.map(\.text)
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    defer { semaphore.signal() }
                    do {
                        let vectors = try await service.embedBatch(texts: texts, configuration: embConfig)
                        for (i, vector) in vectors.enumerated() where i < items.count {
                            try? store.upsertEmbedding(
                                targetType: "file_summary",
                                targetId: items[i].id,
                                contentHash: items[i].hash,
                                model: vector.model,
                                vector: vector.values
                            )
                        }
                    } catch {
                        // Non-fatal
                    }
                }
                semaphore.wait()

                embedded += batch.count
                let progress = embedded
                let total = files.count
                await MainActor.run {
                    self.memoryIndexProgress = "Embedded \(progress)/\(total) files"
                }
            }

            let embCount = store.embeddingCount(targetType: "file_summary")
            await MainActor.run {
                self.embeddingCount = embCount
                self.embeddingsAvailable = true
                self.isIndexingMemory = false
                self.memoryIndexProgress = ""
                self.statusMessage = "Embedding complete: \(embCount) file summaries embedded."
            }
        }
    }

    func selectedFile() -> RepoFile? {
        guard let repo, let selectedFilePath else { return nil }
        return repo.files.first { $0.relativePath == selectedFilePath }
    }

    func ask(_ query: String, configuration: DeepSeekConfiguration, embeddingConfig: EmbeddingConfiguration = .disabled,
             evidenceBuilderConfig: EvidenceBuilderConfiguration = .disabled) {
        guard let repo else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        latestQuestion = trimmed
        isAsking = true
        retrievalDebugSummary = ""
        evidenceBuilderDiagnostics = ""
        evidenceBuilderActive = false
        latestDossier = nil

        // Use retrieval-based context if repo memory is available
        let useRetrieval = repoMemoryIndexed && !repoMemoryStale
        let embConfig = embeddingConfig
        let ebConfig = evidenceBuilderConfig

        if useRetrieval {
            statusMessage = "Retrieving context from repo memory..."
        } else {
            statusMessage = "Building repo context (legacy mode)..."
        }

        Task(priority: .userInitiated) { [retriever, contextAssembler, contextBuilder, evidenceBuilder] in
            let context: AIContext

            // Compute query embedding if embeddings are available
            var queryEmbedding: EmbeddingVector? = nil
            if embConfig.isAvailable {
                let service = EmbeddingService()
                queryEmbedding = try? await service.embed(text: trimmed, configuration: embConfig)
            }

            // Phase 1: Standard retrieval (always runs to provide seeds)
            var retrieval: RetrievalResult? = nil
            if useRetrieval {
                retrieval = retriever.retrieve(query: trimmed, repoRoot: repo.rootPath, embeddingConfig: embConfig, queryEmbedding: queryEmbedding)
            }

            // Phase 2: Evidence Builder (if enabled and retrieval succeeded)
            if ebConfig.isAvailable, useRetrieval {
                await MainActor.run {
                    self.evidenceBuilderActive = true
                    self.statusMessage = "Evidence builder: starting multi-pass analysis..."
                }

                let dossier = await evidenceBuilder.buildDossier(
                    query: trimmed,
                    repoRoot: repo.rootPath,
                    initialRetrieval: retrieval,
                    configuration: ebConfig,
                    deepSeekConfig: configuration,
                    progress: { progressMsg in
                        Task { @MainActor in
                            self.evidenceBuilderProgress = progressMsg
                            self.statusMessage = progressMsg
                        }
                    }
                )

                if let dossier = dossier {
                    // Evidence builder succeeded — use dossier for DeepSeek prompt
                    context = contextAssembler.assembleFromDossier(
                        query: trimmed,
                        dossier: dossier,
                        repoDisplayName: repo.displayName
                    )

                    let diagLines = buildDossierDiagnostics(dossier: dossier)
                    let retrievalDebug = retrieval?.debugSummary ?? ""
                    await MainActor.run {
                        self.latestDossier = dossier
                        self.retrievalDebugSummary = retrievalDebug + "\n\n--- Evidence Builder ---\n" + diagLines
                        self.evidenceBuilderDiagnostics = diagLines
                        self.statusMessage = "Querying DeepSeek with evidence dossier (\(dossier.exactEvidence.count) evidence, \(dossier.mustReadFiles.count) files)..."
                    }

                    // Update session with files from dossier
                    let dossierPaths = dossier.mustReadFiles.map(\.path)
                    retriever.updateSession(query: trimmed, retrievedFiles: dossierPaths, repoRoot: repo.rootPath)
                } else {
                    // Evidence builder failed — fall back to standard retrieval context
                    await MainActor.run {
                        self.evidenceBuilderDiagnostics = "Evidence builder returned nil (failed or unavailable)"
                    }

                    if let retrieval = retrieval {
                        context = contextAssembler.assemble(query: trimmed, retrieval: retrieval, repoDisplayName: repo.displayName)
                        let debugSummary = retrieval.debugSummary
                        await MainActor.run {
                            self.retrievalDebugSummary = debugSummary + "\n(evidence builder failed — using standard retrieval)"
                            self.statusMessage = "Querying DeepSeek with retrieval context (\(retrieval.items.count) files)..."
                        }
                        let retrievedPaths = retrieval.items.map(\.filePath)
                        retriever.updateSession(query: trimmed, retrievedFiles: retrievedPaths, repoRoot: repo.rootPath)
                    } else {
                        context = contextBuilder.buildContext(for: trimmed, repo: repo)
                        await MainActor.run {
                            self.retrievalDebugSummary = "Using legacy context (retrieval + evidence builder failed)"
                        }
                    }
                }
            } else if let retrieval = retrieval {
                // Standard retrieval path (no evidence builder)
                context = contextAssembler.assemble(query: trimmed, retrieval: retrieval, repoDisplayName: repo.displayName)

                let debugSummary = retrieval.debugSummary
                await MainActor.run {
                    self.retrievalDebugSummary = debugSummary
                    self.statusMessage = "Querying DeepSeek with retrieval context (\(retrieval.items.count) files)..."
                }

                // Update session memory
                let retrievedPaths = retrieval.items.map(\.filePath)
                retriever.updateSession(query: trimmed, retrievedFiles: retrievedPaths, repoRoot: repo.rootPath)
            } else {
                // Fallback to legacy context builder
                context = contextBuilder.buildContext(for: trimmed, repo: repo)
                await MainActor.run {
                    self.retrievalDebugSummary = "Using legacy context (repo memory not available)"
                }
            }

            let contextEntry = ContextCacheEntry(
                repoHash: repo.repoHash,
                contextKey: context.cacheKey,
                createdAt: Date(),
                slices: context.slices,
                tokenEstimate: context.tokenEstimate
            )
            cache.store(context: contextEntry)

            await MainActor.run {
                self.latestContextSlices = context.slices
                self.evidenceBuilderActive = false
            }

            if let cached = cache.cachedAnswer(repoHash: repo.repoHash, contextKey: context.cacheKey, query: trimmed) {
                await MainActor.run {
                    self.latestAnswer = cached.answer
                    self.isAsking = false
                    self.statusMessage = "Loaded cached answer for \"\(trimmed)\"."
                }
                return
            }

            do {
                let answer = try await aiService.ask(prompt: context.prompt, configuration: configuration)
                let cacheEntry = AnswerCacheEntry(
                    query: trimmed,
                    answer: answer,
                    repoHash: repo.repoHash,
                    contextKey: context.cacheKey,
                    createdAt: Date()
                )
                cache.store(answer: cacheEntry)

                let source = self.latestDossier != nil ? "evidence-dossier" : "retrieval-driven"
                await MainActor.run {
                    self.latestAnswer = answer
                    self.isAsking = false
                    self.statusMessage = "DeepSeek answer ready (\(source))."
                }
            } catch {
                let fallback = cache.cachedAnswer(repoHash: repo.repoHash, contextKey: context.cacheKey, query: trimmed)?.answer
                await MainActor.run {
                    self.latestAnswer = fallback ?? "No live DeepSeek answer is available. \(error.localizedDescription)"
                    self.isAsking = false
                    self.statusMessage = fallback == nil ? "DeepSeek unavailable." : "Showing cached answer due to request failure."
                }
            }
        }
    }

    /// Build human-readable diagnostics from a dossier.
    private nonisolated func buildDossierDiagnostics(dossier: EvidenceDossier) -> String {
        let diag = dossier.builderDiagnostics
        var lines: [String] = []
        lines.append("PADA+ Dossier Diagnostics")
        lines.append("Query type: \(dossier.queryIntent.primary.rawValue) (conf=\(String(format: "%.2f", dossier.queryIntent.confidence)))")
        lines.append("Policy: hops=\(dossier.queryPolicy.graphHops) maxFiles=\(dossier.queryPolicy.maxFiles) segs/file=\(dossier.queryPolicy.maxSegmentsPerFile) symDepth=\(dossier.queryPolicy.symbolTraversalDepth)")
        lines.append("Terms: \(dossier.queryIntent.extractedTerms.prefix(8).joined(separator: ", "))")
        if !dossier.queryIntent.symbolHints.isEmpty {
            lines.append("Symbols: \(dossier.queryIntent.symbolHints.joined(separator: ", "))")
        }
        lines.append("Model: \(diag.usedModel)\(diag.fallbackUsed ? " (fallback)" : "")")
        lines.append("Candidates: \(diag.totalCandidatesConsidered) → \(dossier.mustReadFiles.count) must-read")
        lines.append("Segments examined: \(diag.totalSegmentsExamined)")
        lines.append("Builder tokens: ~\(diag.totalBuilderTokensUsed)")
        lines.append("Dossier tokens: ~\(diag.dossierTokenEstimate)")
        lines.append("Elapsed: \(diag.elapsedMs)ms")
        lines.append("")
        lines.append("Coverage:")
        let cov = dossier.coverageReport
        lines.append("  Terms: \(String(format: "%.0f%%", cov.queryTermCoverage * 100)) | Symbols: \(String(format: "%.0f%%", cov.symbolDefinitionCoverage * 100)) | Imports: \(String(format: "%.0f%%", cov.importGraphCoverage * 100))")
        lines.append("  Files: \(cov.filesExamined)/\(cov.totalFirstPartyFiles) examined, \(cov.filesIncluded) in evidence")
        if !cov.gaps.isEmpty {
            lines.append("  Gaps (\(cov.gaps.count)):")
            for gap in cov.gaps.prefix(8) {
                lines.append("    [\(gap.gapType.rawValue)] \(gap.area): \(gap.description)")
            }
        }
        lines.append("")
        lines.append("Confidence: overall=\(String(format: "%.2f", dossier.confidenceReport.overall)) impl=\(String(format: "%.2f", dossier.confidenceReport.implementationCoverage)) docs=\(String(format: "%.2f", dossier.confidenceReport.docCoverage)) path=\(String(format: "%.2f", dossier.confidenceReport.executionPathConfidence))")
        lines.append("Evidence: \(dossier.exactEvidence.count) exact, \(dossier.supportingContext.count) supporting, \(dossier.missingEvidence.count) missing")
        lines.append("Builder version: \(DossierCache.builderVersion)")
        lines.append("")
        lines.append("Pipeline stages:")
        for stage in diag.stages {
            lines.append("  [\(stage.name)] \(stage.candidatesIn)→\(stage.candidatesOut) ~\(stage.tokensUsed)tok \(stage.durationMs)ms \(stage.notes)")
        }

        // Implementation path summary
        if !dossier.implementationPath.steps.isEmpty {
            lines.append("")
            lines.append("Implementation path (\(dossier.implementationPath.steps.count) steps):")
            for step in dossier.implementationPath.steps.prefix(8) {
                lines.append("  \(step.order). [\(step.role)] \(step.path):\(step.symbol)")
            }
        }

        // Dropped candidates
        if !dossier.droppedCandidates.isEmpty {
            lines.append("")
            lines.append("Dropped: \(dossier.droppedCandidates.count) candidates")
        }

        return lines.joined(separator: "\n")
    }

    func summarizeRepository(configuration: DeepSeekConfiguration, embeddingConfig: EmbeddingConfiguration = .disabled,
                              evidenceBuilderConfig: EvidenceBuilderConfiguration = .disabled) {
        ask("Give me a concise repo tour. Explain the entry points, major zones, high-signal files, and what I should read first.",
            configuration: configuration, embeddingConfig: embeddingConfig, evidenceBuilderConfig: evidenceBuilderConfig)
    }

    func figureOutLaunchpadPlan(configuration: DeepSeekConfiguration) {
        guard let repo else {
            launchpadPlanningError = "Load a repository first."
            return
        }
        guard !isPlanningLaunchpad, !isRunningLaunchpad else { return }

        isPlanningLaunchpad = true
        launchpadPlanningError = nil
        launchpadPlanningNotice = nil
        launchpadRunError = nil
        launchpadPlan = nil
        launchpadContextFiles = []
        clearWebPreviewState()
        launchpadExitCode = nil
        launchpadLaunchedAppPath = nil
        launchpadExecutionCommandDisplay = nil
        launchpadResolvedExecutableMessage = nil
        launchpadEnvironmentMessage = nil
        clearPythonSetupState()
        launchpadFailureClassificationMessage = nil
        launchpadPlannerRawResponse = nil
        resetNativeLaunchState()
        launchpadStopRequested = false
        statusMessage = "Launchpad is detecting local run options..."

        let localWebDetection = webRunDetector.detect(repo: repo)
        if let localPlan = localWebDetection.plan {
            launchpadPlan = localPlan
            launchpadPlanningNotice = "Local web run plan detected. Asking DeepSeek for optional refinement."
            updatePlannedPreviewURLFromPlan(localPlan)
            refreshPythonSetupStateAndExecutionPreview(repo: repo, plan: localPlan)
        } else if let failure = localWebDetection.failureReason, !failure.isEmpty {
            launchpadPlanningNotice = failure
        }

        if !configuration.isConfigured {
            isPlanningLaunchpad = false
            if launchpadPlan != nil {
                statusMessage = "Launchpad plan ready (local detection only). Review and approve before running."
                return
            }

            launchpadPlanningError = localWebDetection.failureReason ?? "No local run plan detected and DeepSeek is not configured."
            statusMessage = "Launchpad planning failed."
            return
        }

        statusMessage = localWebDetection.plan == nil
            ? "Launchpad is asking DeepSeek for a run plan..."
            : "Launchpad detected a local plan and is asking DeepSeek for refinement..."

        Task(priority: .userInitiated) {
            // Use repo memory for launchpad context if available
            let context: RepoRunContext
            if self.repoMemoryIndexed,
               let memCtx = contextAssembler.assembleForLaunchpad(
                   repoRoot: repo.rootPath,
                   repoDisplayName: repo.displayName,
                   languageCounts: repo.summary.languageCounts,
                   topFiles: repo.summary.topFiles.map(\.relativePath),
                   containers: self.discoverProjectContainersSync(in: URL(fileURLWithPath: repo.rootPath))
               ) {
                context = memCtx
            } else {
                context = runContextBuilder.buildContext(repo: repo)
            }
            do {
                let plannerResult = try await runPlanner.planRun(context: context, configuration: configuration)
                await MainActor.run {
                    self.launchpadPlannerRawResponse = plannerResult.rawResponse
                    if self.isRunningLaunchpad {
                        self.isPlanningLaunchpad = false
                        self.launchpadPlanningNotice = "DeepSeek refinement completed while a run was already in progress."
                        return
                    }

                    let finalPlan: LaunchpadRunPlan
                    if let localPlan = localWebDetection.plan {
                        finalPlan = self.refinedLocalPlan(localPlan: localPlan, deepSeekPlan: plannerResult.plan)
                        self.launchpadPlanningNotice = "Using deterministic local web plan with DeepSeek refinement."
                    } else {
                        finalPlan = plannerResult.plan
                        self.launchpadPlanningNotice = nil
                    }

                    self.launchpadPlan = finalPlan
                    self.launchpadContextFiles = context.includedFiles
                    self.isPlanningLaunchpad = false
                    self.statusMessage = finalPlan.isRunnable
                        ? "Launchpad plan ready. Review and approve before running."
                        : "Launchpad found blockers. Review plan details."
                    self.updatePlannedPreviewURLFromPlan(finalPlan)
                    self.refreshPythonSetupStateAndExecutionPreview(repo: repo, plan: finalPlan)
                }
            } catch {
                await MainActor.run {
                    self.isPlanningLaunchpad = false
                    if self.isRunningLaunchpad {
                        self.launchpadPlanningNotice = "DeepSeek refinement failed while a run was in progress."
                        return
                    }
                    if let plannerError = error as? DeepSeekRunPlanner.PlannerError {
                        self.launchpadPlannerRawResponse = plannerError.rawResponse
                    }

                    if let localPlan = localWebDetection.plan {
                        self.launchpadPlan = localPlan
                        self.launchpadContextFiles = context.includedFiles
                        self.launchpadPlanningError = nil
                        self.launchpadPlanningNotice = self.deepSeekFallbackNotice(for: error, hasLocalPlan: true)
                        self.statusMessage = localPlan.isRunnable
                            ? "Launchpad plan ready from local detection. Review and approve before running."
                            : "Launchpad local plan found blockers."
                        self.updatePlannedPreviewURLFromPlan(localPlan)
                        self.refreshPythonSetupStateAndExecutionPreview(repo: repo, plan: localPlan)
                    } else {
                        self.launchpadPlan = nil
                        self.launchpadContextFiles = context.includedFiles
                        self.launchpadPlanningNotice = self.deepSeekFallbackNotice(for: error, hasLocalPlan: false)
                        self.launchpadPlanningError = self.planningFailureMessage(
                            deepSeekError: error,
                            localDetectionFailure: localWebDetection.failureReason
                        )
                        self.statusMessage = "Launchpad planning failed."
                    }
                }
            }
        }
    }

    func runApprovedLaunchpadPlan() {
        guard let repo, let plan = launchpadPlan else { return }
        guard !isRunningLaunchpad else { return }
        guard plan.isRunnable else {
            launchpadRunError = plan.blocker ?? "This plan is marked as not runnable."
            return
        }

        if plan.outputMode == .nativeApp {
            runNativeLaunchPipeline(plan: plan, repo: repo)
            return
        }

        launchpadStopRequested = false
        launchpadExecutionCommandDisplay = nil
        launchpadResolvedExecutableMessage = nil
        launchpadEnvironmentMessage = nil
        launchpadFailureClassificationMessage = nil
        resetNativeLaunchState()
        launchpadWebReadinessTask?.cancel()
        launchpadWebReadinessTask = nil

        let workingDirectory: URL
        do {
            workingDirectory = try resolveWorkingDirectory(planWorkingDirectory: plan.workingDirectory, repoRootPath: repo.rootPath)
        } catch {
            launchpadRunError = error.localizedDescription
            return
        }

        let resolvedCommand: ExecutableResolver.ResolvedCommand
        do {
            resolvedCommand = try executableResolver.resolve(
                command: plan.command.trimmingCharacters(in: .whitespacesAndNewlines),
                args: plan.args,
                repoRoot: URL(fileURLWithPath: repo.rootPath)
            )
        } catch {
            launchpadRunError = error.localizedDescription
            return
        }

        if isUnsafe(command: resolvedCommand.command, args: resolvedCommand.args) {
            launchpadRunError = "Launchpad blocked this command for safety. Adjust plan manually."
            return
        }

        launchpadRunError = nil
        launchpadExitCode = nil
        launchpadLaunchedAppPath = nil
        clearLaunchpadLogState()
        launchpadExecutionCommandDisplay = commandDisplay(command: resolvedCommand.command, args: resolvedCommand.args)
        launchpadResolvedExecutableMessage = resolvedCommand.resolvedExecutableMessage
        launchpadEnvironmentMessage = resolvedCommand.environmentMessage
        launchpadLivePreviewURL = nil
        updatePlannedPreviewURLFromPlan(plan)
        isRunningLaunchpad = true
        isBootstrappingPythonEnvironment = false
        if plan.outputMode == .webPreview {
            launchpadWebStartupStatus = "Launching dev server..."
        } else {
            launchpadWebStartupStatus = nil
        }
        statusMessage = "Launchpad running: \(launchpadExecutionCommandDisplay ?? plan.commandDisplay)"

        if let resolutionMessage = resolvedCommand.resolvedExecutableMessage, !resolutionMessage.isEmpty {
            appendLaunchpadLog(text: resolutionMessage, isStdErr: false)
        }
        if let environmentMessage = resolvedCommand.environmentMessage, !environmentMessage.isEmpty {
            appendLaunchpadLog(text: environmentMessage, isStdErr: false)
        }

        do {
            try processRunner.run(
                command: resolvedCommand.command,
                args: resolvedCommand.args,
                workingDirectory: workingDirectory,
                environmentOverrides: resolvedCommand.environmentOverrides,
                onOutput: { [weak self] text, isStdErr in
                    guard let self else { return }
                    self.appendLaunchpadLog(text: text, isStdErr: isStdErr)
                    self.handleWebProcessOutputIfNeeded(from: text)
                },
                onExit: { [weak self] exitCode in
                    guard let self else { return }
                    self.isRunningLaunchpad = false
                    self.launchpadExitCode = exitCode
                    self.stopWebReadinessMonitoring()
                    self.flushLaunchpadLogsForUI(force: true)

                    if self.launchpadStopRequested {
                        self.statusMessage = "Launchpad run stopped."
                        if plan.outputMode == .webPreview {
                            self.launchpadWebStartupStatus = "Stopped."
                        }
                        return
                    }

                    if exitCode == 0 {
                        self.statusMessage = "Launchpad run completed."
                        if plan.outputMode == .webPreview, self.launchpadLivePreviewURL == nil {
                            self.launchpadWebStartupStatus = "Run completed before a localhost preview became reachable."
                        }
                    } else {
                        self.statusMessage = "Launchpad run exited with code \(exitCode)."
                        if plan.outputMode == .webPreview, self.launchpadLivePreviewURL == nil {
                            self.launchpadWebStartupStatus = "Process exited before server became ready."
                        }
                        self.handleLaunchFailureIfNeeded(plan: plan, repo: repo, exitCode: exitCode)
                    }
                }
            )
            if plan.outputMode == .webPreview {
                startWebReadinessMonitoring()
            }
        } catch {
            isRunningLaunchpad = false
            launchpadRunError = "Failed to start process: \(error.localizedDescription)"
            statusMessage = "Launchpad could not start the process."
            if plan.outputMode == .webPreview {
                launchpadWebStartupStatus = "Failed to launch dev server."
            }
        }
    }

    func setUpPythonEnvironment() {
        guard let repo, let plan = launchpadPlan else { return }
        guard !isRunningLaunchpad else { return }
        guard isPythonCommand(plan.command) else {
            launchpadRunError = "Environment setup is only available for Python run plans."
            return
        }
        guard !launchpadBootstrapPlanCommands.isEmpty else {
            launchpadRunError = launchpadBootstrapReason ?? "No Python bootstrap plan is available."
            return
        }

        launchpadStopRequested = false
        launchpadRunError = nil
        launchpadExitCode = nil
        clearLaunchpadLogState()
        launchpadFailureClassificationMessage = nil
        isRunningLaunchpad = true
        isBootstrappingPythonEnvironment = true
        statusMessage = "Setting up Python environment..."

        let repoRoot = URL(fileURLWithPath: repo.rootPath)
        Task { @MainActor in
            do {
                for command in launchpadBootstrapPlanCommands {
                    if self.launchpadStopRequested {
                        throw CancellationError()
                    }
                    self.appendLaunchpadLog(text: "$ \(command.display)", isStdErr: false)
                    let exitCode = try await self.runCommandAndWait(
                        command: command.command,
                        args: command.args,
                        workingDirectory: repoRoot,
                        environmentOverrides: [:]
                    )
                    if self.launchpadStopRequested {
                        throw CancellationError()
                    }
                    if exitCode != 0 {
                        throw NSError(
                            domain: "RepoAtlas.Launchpad",
                            code: Int(exitCode),
                            userInfo: [NSLocalizedDescriptionKey: "Bootstrap command failed (\(exitCode)): \(command.display)"]
                        )
                    }
                }

                self.isRunningLaunchpad = false
                self.isBootstrappingPythonEnvironment = false
                self.launchpadSetupRequired = false
                self.launchpadBootstrapReason = nil
                self.launchpadBootstrapCommands = []
                self.launchpadBootstrapPlanCommands = []
                self.statusMessage = "Python environment setup complete. Ready to rerun."
                self.appendLaunchpadLog(text: "Python environment setup complete.", isStdErr: false)
                self.updateExecutionPreview(repo: repo, plan: plan)
            } catch is CancellationError {
                self.isRunningLaunchpad = false
                self.isBootstrappingPythonEnvironment = false
                self.statusMessage = "Python environment setup stopped."
            } catch {
                self.isRunningLaunchpad = false
                self.isBootstrappingPythonEnvironment = false
                self.launchpadRunError = error.localizedDescription
                self.statusMessage = "Python environment setup failed."
            }
        }
    }

    func rerunLaunchpadPlan() {
        runApprovedLaunchpadPlan()
    }

    func stopLaunchpadRun() {
        launchpadStopRequested = true
        stopWebReadinessMonitoring()
        processRunner.stop()
        if let process = launchpadNativeExecutableProcess, process.isRunning {
            process.terminate()
        }
        launchpadNativeExecutableProcess = nil
        launchpadLaunchedNativeProcessIdentifier = nil
        if isRunningLaunchpad || isBootstrappingPythonEnvironment {
            isRunningLaunchpad = false
            isBootstrappingPythonEnvironment = false
            statusMessage = "Launchpad run stopped."
            flushLaunchpadLogsForUI(force: true)
            if launchpadPlan?.outputMode == .webPreview {
                launchpadWebStartupStatus = "Stopped."
            } else if launchpadPlan?.outputMode == .nativeApp {
                launchpadNativeStatus = "Stopped."
            }
        }
    }

    func openLaunchpadPreviewInBrowser() {
        guard let url = launchpadLivePreviewURL else { return }
        NSWorkspace.shared.open(url)
    }

    func focusLaunchedNativeApp() {
        if let pid = launchpadLaunchedNativeProcessIdentifier,
           let running = NSRunningApplication(processIdentifier: pid) {
            _ = running.activate(options: [.activateIgnoringOtherApps])
            return
        }
        guard let path = launchpadLaunchedAppPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openLaunchpadNativeTarget() {
        guard let path = launchpadNativeLaunchTargetPath else { return }
        let targetURL = URL(fileURLWithPath: path)
        if targetURL.pathExtension.lowercased() == "app" {
            NSWorkspace.shared.open(targetURL)
            return
        }

        let workingDirectory = repo.map { URL(fileURLWithPath: $0.rootPath) } ?? targetURL.deletingLastPathComponent()
        do {
            let process = try startNativeExecutable(executablePath: path, workingDirectory: workingDirectory)
            launchpadNativeExecutableProcess = process
            launchpadLaunchedNativeProcessIdentifier = process.processIdentifier
            launchpadLaunchedAppPath = path
        } catch {
            launchpadRunError = "Failed to launch native executable: \(error.localizedDescription)"
        }
    }

    func relaunchLaunchpadNativeTarget() {
        openLaunchpadNativeTarget()
    }

    private func deepSeekFallbackNotice(for error: Error, hasLocalPlan: Bool) -> String {
        if let plannerError = error as? DeepSeekRunPlanner.PlannerError {
            if plannerError.isParseFailure {
                return hasLocalPlan
                    ? "DeepSeek plan parse failed; using local detected plan."
                    : "No valid RunPlan returned; falling back to local detection."
            }
            return "No valid RunPlan returned; falling back to local detection."
        }
        return hasLocalPlan
            ? "DeepSeek planning failed; using local detected plan."
            : "DeepSeek planning failed; local detection fallback did not find a runnable plan."
    }

    private func planningFailureMessage(deepSeekError: Error, localDetectionFailure: String?) -> String {
        if let plannerError = deepSeekError as? DeepSeekRunPlanner.PlannerError {
            if plannerError.isParseFailure {
                if let localDetectionFailure, !localDetectionFailure.isEmpty {
                    return localDetectionFailure
                }
                return "DeepSeek returned an unreadable run plan and no deterministic local plan was detected."
            }
            if let localDetectionFailure, !localDetectionFailure.isEmpty {
                return localDetectionFailure
            }
            return "No valid RunPlan returned; falling back to local detection."
        }

        if let localDetectionFailure, !localDetectionFailure.isEmpty {
            return localDetectionFailure
        }
        return deepSeekError.localizedDescription
    }

    private func refinedLocalPlan(localPlan: LaunchpadRunPlan, deepSeekPlan: LaunchpadRunPlan) -> LaunchpadRunPlan {
        let refinedPort = localPlan.port ?? deepSeekPlan.port
        let deepSeekReason = deepSeekPlan.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let refinementNote = deepSeekReason.isEmpty ? nil : "DeepSeek analysis: \(deepSeekReason)"
        let mergedNotes: String?
        if let existing = localPlan.launchNotes, !existing.isEmpty, let refinementNote {
            mergedNotes = existing + "\n" + refinementNote
        } else {
            mergedNotes = localPlan.launchNotes ?? refinementNote
        }

        return LaunchpadRunPlan(
            projectType: localPlan.projectType,
            command: localPlan.command,
            args: localPlan.args,
            workingDirectory: localPlan.workingDirectory,
            outputMode: localPlan.outputMode,
            port: refinedPort,
            confidence: max(localPlan.confidence, deepSeekPlan.confidence),
            reason: localPlan.reason,
            launchNotes: mergedNotes,
            isRunnable: localPlan.isRunnable,
            blocker: localPlan.blocker,
            appBundlePath: localPlan.appBundlePath
        )
    }

    private func updatePlannedPreviewURLFromPlan(_ plan: LaunchpadRunPlan) {
        launchpadLivePreviewURL = nil
        if plan.outputMode == .webPreview, let port = plan.port {
            launchpadPlannedPreviewURL = URL(string: "http://127.0.0.1:\(port)")
            launchpadWebStartupStatus = "Planned preview URL: http://127.0.0.1:\(port)"
        } else if plan.outputMode == .webPreview {
            launchpadPlannedPreviewURL = nil
            launchpadWebStartupStatus = "Web preview URL will be detected after launch."
        } else {
            launchpadPlannedPreviewURL = nil
            launchpadWebStartupStatus = nil
        }
    }

    private func clearWebPreviewState() {
        stopWebReadinessMonitoring()
        launchpadPlannedPreviewURL = nil
        launchpadLivePreviewURL = nil
        launchpadWebStartupStatus = nil
    }

    private func clearLaunchpadLogState() {
        launchpadLogFlushTask?.cancel()
        launchpadLogFlushTask = nil
        launchpadPendingLogFlush = false
        launchpadAllLogs = []
        launchpadLogs = []
        launchpadLogLineCount = 0
        launchpadTerminalOutputExpanded = true
        launchpadDidAutoCollapseLogs = false
    }

    private func resetNativeLaunchState() {
        launchpadNativeStrategy = nil
        launchpadNativeStatus = nil
        launchpadNativeBuildCommandDisplay = nil
        launchpadNativeBuildSucceeded = nil
        launchpadNativeLaunchTargetPath = nil
        launchpadNativeIsGUIApp = false
        launchpadNativeExecutableProcess = nil
        launchpadLaunchedNativeProcessIdentifier = nil
    }

    private func resetLaunchpadState() {
        clearWebPreviewState()
        clearLaunchpadLogState()
        launchpadPlan = nil
        launchpadContextFiles = []
        isPlanningLaunchpad = false
        isRunningLaunchpad = false
        launchpadPlanningError = nil
        launchpadPlanningNotice = nil
        launchpadRunError = nil
        launchpadExitCode = nil
        launchpadLaunchedAppPath = nil
        launchpadExecutionCommandDisplay = nil
        launchpadResolvedExecutableMessage = nil
        launchpadEnvironmentMessage = nil
        clearPythonSetupState()
        launchpadFailureClassificationMessage = nil
        launchpadPlannerRawResponse = nil
        resetNativeLaunchState()
        isBootstrappingPythonEnvironment = false
        launchpadStopRequested = false
    }

    private func clearPythonSetupState() {
        launchpadSetupRequired = false
        launchpadBootstrapReason = nil
        launchpadBootstrapCommands = []
        launchpadBootstrapPlanCommands = []
    }

    private func discoverProjectContainersSync(in rootURL: URL) -> [String] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return [] }
        var hits: [String] = []
        while let item = enumerator.nextObject() as? URL {
            let last = item.lastPathComponent
            if AppConstants.ignoredDirectories.contains(last) {
                enumerator.skipDescendants()
                continue
            }
            if last.hasSuffix(".xcodeproj") || last.hasSuffix(".xcworkspace") {
                hits.append(item.path.replacingOccurrences(of: rootURL.path + "/", with: ""))
            }
            if hits.count >= 20 { break }
        }
        return hits.sorted()
    }

    private func refreshPythonSetupStateAndExecutionPreview(repo: RepoModel, plan: LaunchpadRunPlan) {
        if isPythonCommand(plan.command) {
            do {
                if let bootstrapPlan = try pythonBootstrapPlanner.planIfNeeded(
                    repoRoot: URL(fileURLWithPath: repo.rootPath),
                    command: plan.command,
                    args: plan.args,
                    trigger: .proactive
                ) {
                    launchpadSetupRequired = true
                    launchpadBootstrapReason = bootstrapPlan.reason
                    launchpadBootstrapPlanCommands = bootstrapPlan.commands
                    launchpadBootstrapCommands = bootstrapPlan.commands.map(\.display)
                } else {
                    clearPythonSetupState()
                }
            } catch {
                launchpadSetupRequired = true
                launchpadBootstrapReason = error.localizedDescription
                launchpadBootstrapPlanCommands = []
                launchpadBootstrapCommands = []
            }
        } else {
            clearPythonSetupState()
        }
        updateExecutionPreview(repo: repo, plan: plan)
    }

    private func updateExecutionPreview(repo: RepoModel, plan: LaunchpadRunPlan) {
        do {
            let resolved = try executableResolver.resolve(
                command: plan.command.trimmingCharacters(in: .whitespacesAndNewlines),
                args: plan.args,
                repoRoot: URL(fileURLWithPath: repo.rootPath)
            )
            launchpadExecutionCommandDisplay = commandDisplay(command: resolved.command, args: resolved.args)
            launchpadResolvedExecutableMessage = resolved.resolvedExecutableMessage
            launchpadEnvironmentMessage = resolved.environmentMessage
        } catch {
            launchpadExecutionCommandDisplay = nil
            launchpadResolvedExecutableMessage = nil
            launchpadEnvironmentMessage = nil
        }
    }

    private func runCommandAndWait(
        command: String,
        args: [String],
        workingDirectory: URL,
        environmentOverrides: [String: String]
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try processRunner.run(
                    command: command,
                    args: args,
                    workingDirectory: workingDirectory,
                    environmentOverrides: environmentOverrides,
                    onOutput: { [weak self] text, isStdErr in
                        self?.appendLaunchpadLog(text: text, isStdErr: isStdErr)
                    },
                    onExit: { exitCode in
                        continuation.resume(returning: exitCode)
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func handleLaunchFailureIfNeeded(plan: LaunchpadRunPlan, repo: RepoModel, exitCode: Int32) {
        guard isPythonCommand(plan.command) else { return }

        let classification = failureClassifier.classifyPythonFailure(
            logs: launchpadAllLogs,
            runError: launchpadRunError,
            exitCode: exitCode,
            repoRoot: URL(fileURLWithPath: repo.rootPath)
        )
        launchpadFailureClassificationMessage = classification?.message

        guard let kind = classification?.kind else { return }
        switch kind {
        case .missingDependency, .missingInterpreter:
            do {
                if let bootstrap = try pythonBootstrapPlanner.planIfNeeded(
                    repoRoot: URL(fileURLWithPath: repo.rootPath),
                    command: plan.command,
                    args: plan.args,
                    trigger: .failure(kind: kind)
                ) {
                    launchpadSetupRequired = true
                    launchpadBootstrapReason = bootstrap.reason
                    launchpadBootstrapPlanCommands = bootstrap.commands
                    launchpadBootstrapCommands = bootstrap.commands.map(\.display)
                    if launchpadRunError?.isEmpty ?? true {
                        launchpadRunError = bootstrap.reason
                    }
                    statusMessage = "Environment setup required before Python run."
                } else {
                    clearPythonSetupState()
                }
            } catch {
                launchpadSetupRequired = true
                launchpadBootstrapReason = error.localizedDescription
                launchpadBootstrapPlanCommands = []
                launchpadBootstrapCommands = []
                launchpadRunError = error.localizedDescription
                statusMessage = "Python environment setup is required but could not be prepared."
            }
        case .repoImportMismatch:
            clearPythonSetupState()
            if launchpadRunError?.isEmpty ?? true {
                launchpadRunError = classification?.message
            }
            statusMessage = "Run failed due to a repo import/code mismatch."
        case .versionIncompatibility:
            clearPythonSetupState()
            if launchpadRunError?.isEmpty ?? true {
                launchpadRunError = classification?.message
            }
            statusMessage = "Run failed due to Python version incompatibility."
        case .runtimeFailure:
            break
        }
    }

    private func appendLaunchpadLog(text: String, isStdErr: Bool) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var didAppend = false
        for line in lines where !line.isEmpty {
            launchpadAllLogs.append(isStdErr ? "[stderr] \(line)" : line)
            didAppend = true
        }
        if launchpadAllLogs.count > launchpadLogLimit {
            launchpadAllLogs.removeFirst(launchpadAllLogs.count - launchpadLogLimit)
        }
        guard didAppend else { return }
        scheduleLaunchpadLogFlush()
    }

    private func scheduleLaunchpadLogFlush() {
        launchpadPendingLogFlush = true
        guard launchpadLogFlushTask == nil else { return }

        launchpadLogFlushTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.launchpadLogFlushIntervalNanoseconds)
                if self.launchpadPendingLogFlush {
                    self.launchpadPendingLogFlush = false
                    self.flushLaunchpadLogsForUI(force: false)
                    continue
                }

                self.launchpadLogFlushTask = nil
                return
            }
        }
    }

    private func flushLaunchpadLogsForUI(force: Bool) {
        launchpadLogLineCount = launchpadAllLogs.count

        if !launchpadDidAutoCollapseLogs,
           isRunningLaunchpad,
           launchpadAllLogs.count >= launchpadAutoCollapseThreshold {
            launchpadTerminalOutputExpanded = false
            launchpadDidAutoCollapseLogs = true
        }

        guard force || launchpadTerminalOutputExpanded else { return }
        launchpadLogs = launchpadAllLogs
        if launchpadLogs.count > launchpadLogLimit {
            launchpadLogs.removeFirst(launchpadLogs.count - launchpadLogLimit)
        }
    }

    private func runNativeLaunchPipeline(plan: LaunchpadRunPlan, repo: RepoModel) {
        launchpadStopRequested = false
        launchpadRunError = nil
        launchpadExitCode = nil
        launchpadLaunchedAppPath = nil
        launchpadExecutionCommandDisplay = nil
        launchpadResolvedExecutableMessage = nil
        launchpadEnvironmentMessage = nil
        launchpadFailureClassificationMessage = nil
        clearWebPreviewState()
        clearLaunchpadLogState()
        resetNativeLaunchState()

        isRunningLaunchpad = true
        isBootstrappingPythonEnvironment = false
        launchpadNativeStatus = "Detecting native target…"
        statusMessage = "Detecting native target..."

        let repoRoot = URL(fileURLWithPath: repo.rootPath)
        Task { @MainActor in
            let detection = detectNativeLaunchTarget(plan: plan, repoRoot: repoRoot)
            launchpadNativeStrategy = detection.strategy.rawValue

            if let message = detection.unsupportedMessage {
                launchpadNativeStatus = message
                launchpadRunError = message
                statusMessage = message
                isRunningLaunchpad = false
                return
            }

            switch detection.strategy {
            case .xcodeWorkspace, .xcodeProject:
                guard let containerURL = detection.containerURL, let scheme = detection.scheme else {
                    launchpadNativeStatus = "Could not determine launchable native target."
                    launchpadRunError = launchpadNativeStatus
                    statusMessage = "Could not determine launchable native target."
                    isRunningLaunchpad = false
                    return
                }
                let build = nativeBuildInvocation(strategy: detection.strategy, containerURL: containerURL, scheme: scheme)
                launchpadNativeBuildCommandDisplay = commandDisplay(command: build.command, args: build.args)
                launchpadNativeStatus = "Building…"
                statusMessage = "Building native app..."
                appendLaunchpadLog(text: "$ \(launchpadNativeBuildCommandDisplay ?? "")", isStdErr: false)

                do {
                    let buildExit = try await runCommandAndWait(
                        command: build.command,
                        args: build.args,
                        workingDirectory: repoRoot,
                        environmentOverrides: [:]
                    )
                    launchpadExitCode = buildExit

                    if launchpadStopRequested {
                        launchpadNativeStatus = "Build stopped."
                        statusMessage = "Launchpad run stopped."
                        isRunningLaunchpad = false
                        return
                    }

                    if buildExit != 0 {
                        launchpadNativeBuildSucceeded = false
                        launchpadNativeStatus = "Build failed"
                        launchpadRunError = "Native build failed with exit code \(buildExit)."
                        statusMessage = "Native build failed."
                        isRunningLaunchpad = false
                        return
                    }

                    launchpadNativeBuildSucceeded = true
                    launchpadNativeStatus = "Build succeeded"
                    statusMessage = "Build succeeded. Locating launch target..."

                    if let appURL = resolveBuiltAppBundlePath(
                        strategy: detection.strategy,
                        containerURL: containerURL,
                        scheme: scheme,
                        repoRoot: repoRoot,
                        fallbackAppBundlePath: plan.appBundlePath
                    ) {
                        launchpadNativeLaunchTargetPath = appURL.path
                        launchpadNativeIsGUIApp = true
                        launchpadNativeStatus = "Launching app…"
                        statusMessage = "Launching app..."

                        if NSWorkspace.shared.open(appURL) {
                            launchpadLaunchedAppPath = appURL.path
                            if await didLaunchedAppRemainRunning(appURL: appURL) {
                                launchpadNativeStatus = "App launched"
                                statusMessage = "App launched."
                            } else {
                                launchpadNativeStatus = "App exited immediately"
                                launchpadRunError = "App exited immediately after launch."
                                statusMessage = "App exited immediately."
                            }
                        } else {
                            launchpadNativeStatus = "Could not launch app."
                            launchpadRunError = "Failed to launch app bundle: \(appURL.path)"
                            statusMessage = "Could not launch app."
                        }
                        isRunningLaunchpad = false
                        return
                    }

                    if let executablePath = resolveBuiltExecutablePath(
                        strategy: detection.strategy,
                        containerURL: containerURL,
                        scheme: scheme,
                        repoRoot: repoRoot
                    ) {
                        launchpadNativeLaunchTargetPath = executablePath
                        launchpadNativeIsGUIApp = false
                        launchpadNativeStatus = "Detected target is terminal-only, not GUI app"
                        launchpadRunError = "Detected target is terminal-only, not GUI app."
                        statusMessage = "Detected target is terminal-only, not GUI app."
                        isRunningLaunchpad = false
                        return
                    }

                    launchpadNativeStatus = "Could not determine launchable app bundle"
                    launchpadRunError = "Could not determine launchable app bundle."
                    statusMessage = "Could not determine launchable app bundle."
                    isRunningLaunchpad = false
                } catch {
                    isRunningLaunchpad = false
                    launchpadNativeBuildSucceeded = false
                    launchpadNativeStatus = "Build failed"
                    launchpadRunError = error.localizedDescription
                    statusMessage = "Native build failed."
                }

            case .swiftPackage:
                launchpadNativeStatus = "Building…"
                statusMessage = "Building Swift package..."
                let buildCommand = "/usr/bin/swift"
                let buildArgs = ["build", "-c", "debug"]
                launchpadNativeBuildCommandDisplay = commandDisplay(command: buildCommand, args: buildArgs)
                appendLaunchpadLog(text: "$ \(launchpadNativeBuildCommandDisplay ?? "")", isStdErr: false)

                do {
                    let buildExit = try await runCommandAndWait(
                        command: buildCommand,
                        args: buildArgs,
                        workingDirectory: repoRoot,
                        environmentOverrides: [:]
                    )
                    launchpadExitCode = buildExit
                    if buildExit != 0 {
                        launchpadNativeBuildSucceeded = false
                        launchpadNativeStatus = "Build failed"
                        launchpadRunError = "Swift package build failed with exit code \(buildExit)."
                        statusMessage = "Swift package build failed."
                        isRunningLaunchpad = false
                        return
                    }

                    launchpadNativeBuildSucceeded = true
                    guard let executablePath = resolveSwiftPackageExecutablePath(
                        repoRoot: repoRoot,
                        executableName: detection.swiftPackageExecutableName
                    ) else {
                        launchpadNativeStatus = "Could not determine launchable executable"
                        launchpadRunError = "Swift package build succeeded but no launchable executable was found in .build/debug."
                        statusMessage = "Could not determine launchable executable."
                        isRunningLaunchpad = false
                        return
                    }

                    launchpadNativeLaunchTargetPath = executablePath
                    launchpadNativeStatus = "Built executable found"
                    statusMessage = "Built executable found. Checking GUI capability..."

                    let guiAssessment = assessSwiftPackageGUICapability(
                        repoRoot: repoRoot,
                        executableName: detection.swiftPackageExecutableName
                    )
                    if guiAssessment.likelyGUI {
                        appendLaunchpadLog(
                            text: "GUI-capable signal(s): \(guiAssessment.signals.joined(separator: ", "))",
                            isStdErr: false
                        )
                    } else {
                        appendLaunchpadLog(
                            text: "No strong GUI signals detected in Swift package sources. Launch attempt will verify behavior.",
                            isStdErr: false
                        )
                    }

                    launchpadNativeStatus = "Attempting native executable launch…"
                    statusMessage = "Attempting native executable launch..."

                    switch await launchNativeExecutableWithAssessment(
                        executablePath: executablePath,
                        workingDirectory: repoRoot
                    ) {
                    case .running(let process):
                        launchpadNativeExecutableProcess = process
                        launchpadLaunchedNativeProcessIdentifier = process.processIdentifier
                        launchpadLaunchedAppPath = executablePath

                        if guiAssessment.likelyGUI {
                            launchpadNativeIsGUIApp = true
                            launchpadNativeStatus = "Native executable launched"
                            statusMessage = "Native executable launched."
                        } else {
                            launchpadNativeIsGUIApp = false
                            launchpadNativeStatus = "Could not determine GUI capability"
                            statusMessage = "Executable launched, but GUI capability is unclear."
                        }
                        launchpadRunError = nil
                    case .exited(let code):
                        launchpadExitCode = code
                        launchpadNativeIsGUIApp = false
                        launchpadLaunchedNativeProcessIdentifier = nil
                        launchpadNativeExecutableProcess = nil
                        launchpadLaunchedAppPath = nil

                        if guiAssessment.likelyGUI {
                            launchpadNativeStatus = "Executable exited immediately"
                            launchpadRunError = "Native executable exited immediately (code \(code))."
                            statusMessage = "Native executable exited immediately."
                        } else {
                            launchpadNativeStatus = "Executable appears terminal-only"
                            launchpadRunError = "Swift package executable appears terminal-only (exited with code \(code))."
                            statusMessage = "Executable appears terminal-only."
                        }
                    case .failed(let message):
                        launchpadNativeIsGUIApp = false
                        launchpadLaunchedNativeProcessIdentifier = nil
                        launchpadNativeExecutableProcess = nil
                        launchpadLaunchedAppPath = nil
                        launchpadNativeStatus = "Could not determine GUI capability"
                        launchpadRunError = message
                        statusMessage = "Failed to launch native executable."
                    }
                    isRunningLaunchpad = false
                } catch {
                    isRunningLaunchpad = false
                    launchpadNativeBuildSucceeded = false
                    launchpadNativeStatus = "Build failed"
                    launchpadRunError = error.localizedDescription
                    statusMessage = "Swift package build failed."
                }

            case .unsupported:
                launchpadNativeStatus = "Could not determine native launch strategy."
                launchpadRunError = launchpadNativeStatus
                statusMessage = "Could not determine native launch strategy."
                isRunningLaunchpad = false
            }
        }
    }

    private func detectNativeLaunchTarget(plan: LaunchpadRunPlan, repoRoot: URL) -> (
        strategy: NativeLaunchStrategy,
        containerURL: URL?,
        scheme: String?,
        swiftPackageExecutableName: String?,
        unsupportedMessage: String?
    ) {
        let fileManager = FileManager.default
        let workspaceURLs = findRepositoryItems(withExtension: "xcworkspace", repoRoot: repoRoot)
        if let workspace = workspaceURLs.first {
            let scheme = schemeFromPlanArgs(plan.args) ?? detectXcodeScheme(containerURL: workspace, strategy: .xcodeWorkspace)
            if let scheme {
                return (.xcodeWorkspace, workspace, scheme, nil, nil)
            }
            return (.unsupported, workspace, nil, nil, "Could not determine an Xcode scheme for workspace \(workspace.lastPathComponent).")
        }

        let projectURLs = findRepositoryItems(withExtension: "xcodeproj", repoRoot: repoRoot)
        if let project = projectURLs.first {
            let scheme = schemeFromPlanArgs(plan.args) ?? detectXcodeScheme(containerURL: project, strategy: .xcodeProject)
            if let scheme {
                return (.xcodeProject, project, scheme, nil, nil)
            }
            return (.unsupported, project, nil, nil, "Could not determine an Xcode scheme for project \(project.lastPathComponent).")
        }

        let packageSwift = repoRoot.appendingPathComponent("Package.swift")
        if fileManager.fileExists(atPath: packageSwift.path) {
            return (
                .swiftPackage,
                nil,
                nil,
                swiftPackageExecutableName(from: plan, repoRoot: repoRoot),
                nil
            )
        }

        return (.unsupported, nil, nil, nil, "No supported native launch strategy was detected.")
    }

    private func nativeBuildInvocation(strategy: NativeLaunchStrategy, containerURL: URL, scheme: String) -> (command: String, args: [String]) {
        switch strategy {
        case .xcodeWorkspace:
            return (
                "/usr/bin/xcodebuild",
                ["-workspace", containerURL.path, "-scheme", scheme, "-configuration", "Debug", "-destination", "platform=macOS", "build"]
            )
        case .xcodeProject:
            return (
                "/usr/bin/xcodebuild",
                ["-project", containerURL.path, "-scheme", scheme, "-configuration", "Debug", "-destination", "platform=macOS", "build"]
            )
        case .swiftPackage, .unsupported:
            return ("/usr/bin/true", [])
        }
    }

    private func resolveBuiltAppBundlePath(
        strategy: NativeLaunchStrategy,
        containerURL: URL,
        scheme: String,
        repoRoot: URL,
        fallbackAppBundlePath: String?
    ) -> URL? {
        if let fallback = fallbackAppBundlePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty,
           let resolved = resolveAppBundlePath(fallback, workingDirectory: repoRoot),
           FileManager.default.fileExists(atPath: resolved.path) {
            return resolved
        }

        guard let settings = xcodeBuildSettingsOutput(strategy: strategy, containerURL: containerURL, scheme: scheme, repoRoot: repoRoot) else {
            return nil
        }
        let lines = settings.components(separatedBy: .newlines)

        var builtProductsDir: String?
        var fullProductName: String?
        var targetBuildDir: String?
        var wrapperName: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = captureBuildSetting("BUILT_PRODUCTS_DIR", from: trimmed) {
                builtProductsDir = value
            } else if let value = captureBuildSetting("FULL_PRODUCT_NAME", from: trimmed), value.hasSuffix(".app") {
                fullProductName = value
            } else if let value = captureBuildSetting("TARGET_BUILD_DIR", from: trimmed) {
                targetBuildDir = value
            } else if let value = captureBuildSetting("WRAPPER_NAME", from: trimmed), value.hasSuffix(".app") {
                wrapperName = value
            }

            if let builtProductsDir, let fullProductName {
                let url = URL(fileURLWithPath: builtProductsDir).appendingPathComponent(fullProductName)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
            if let targetBuildDir, let wrapperName {
                let url = URL(fileURLWithPath: targetBuildDir).appendingPathComponent(wrapperName)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    private func resolveBuiltExecutablePath(
        strategy: NativeLaunchStrategy,
        containerURL: URL,
        scheme: String,
        repoRoot: URL
    ) -> String? {
        guard let settings = xcodeBuildSettingsOutput(strategy: strategy, containerURL: containerURL, scheme: scheme, repoRoot: repoRoot) else {
            return nil
        }

        var builtProductsDir: String?
        var executablePath: String?

        for line in settings.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = captureBuildSetting("BUILT_PRODUCTS_DIR", from: trimmed) {
                builtProductsDir = value
            } else if let value = captureBuildSetting("EXECUTABLE_PATH", from: trimmed) {
                executablePath = value
            }

            if let builtProductsDir, let executablePath {
                let url = URL(fileURLWithPath: builtProductsDir).appendingPathComponent(executablePath)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url.path
                }
            }
        }
        return nil
    }

    private func xcodeBuildSettingsOutput(
        strategy: NativeLaunchStrategy,
        containerURL: URL,
        scheme: String,
        repoRoot: URL
    ) -> String? {
        let args: [String]
        switch strategy {
        case .xcodeWorkspace:
            args = ["-workspace", containerURL.path, "-scheme", scheme, "-configuration", "Debug", "-destination", "platform=macOS", "-showBuildSettings"]
        case .xcodeProject:
            args = ["-project", containerURL.path, "-scheme", scheme, "-configuration", "Debug", "-destination", "platform=macOS", "-showBuildSettings"]
        case .swiftPackage, .unsupported:
            return nil
        }

        let result = runProcessCapture(
            executablePath: "/usr/bin/xcodebuild",
            args: args,
            workingDirectory: repoRoot
        )
        guard result.exitCode == 0 else { return nil }
        return result.output
    }

    private func captureBuildSetting(_ key: String, from line: String) -> String? {
        let prefix = "\(key) = "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detectXcodeScheme(containerURL: URL, strategy: NativeLaunchStrategy) -> String? {
        let listArgs: [String]
        switch strategy {
        case .xcodeWorkspace:
            listArgs = ["-workspace", containerURL.path, "-list", "-json"]
        case .xcodeProject:
            listArgs = ["-project", containerURL.path, "-list", "-json"]
        case .swiftPackage, .unsupported:
            return nil
        }

        let result = runProcessCapture(
            executablePath: "/usr/bin/xcodebuild",
            args: listArgs,
            workingDirectory: containerURL.deletingLastPathComponent()
        )
        guard result.exitCode == 0 else { return nil }
        let jsonText = extractJSONObject(from: result.output) ?? result.output
        guard let data = jsonText.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let sectionKey = strategy == .xcodeWorkspace ? "workspace" : "project"
        if let section = object[sectionKey] as? [String: Any],
           let schemes = section["schemes"] as? [String] {
            return schemes.first { !$0.lowercased().contains("pods") } ?? schemes.first
        }
        return nil
    }

    private func schemeFromPlanArgs(_ args: [String]) -> String? {
        guard let index = args.firstIndex(of: "-scheme"), args.indices.contains(index + 1) else { return nil }
        let value = args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func findRepositoryItems(withExtension ext: String, repoRoot: URL, maxDepth: Int = 3) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: repoRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return []
        }

        var results: [URL] = []
        let rootDepth = repoRoot.pathComponents.count
        let excludedDirectories: Set<String> = [".build", ".git", "node_modules", "DerivedData", "Pods"]

        while let item = enumerator.nextObject() as? URL {
            let relativeDepth = item.pathComponents.count - rootDepth
            if relativeDepth > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            if excludedDirectories.contains(item.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }

            if item.pathExtension.lowercased() == ext.lowercased() {
                results.append(item)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    private func swiftPackageExecutableName(from plan: LaunchpadRunPlan, repoRoot: URL) -> String? {
        if plan.command == "swift",
           let runIndex = plan.args.firstIndex(of: "run"),
           plan.args.indices.contains(runIndex + 1) {
            let target = plan.args[runIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty, !target.hasPrefix("-") {
                return target
            }
        }

        let packageSwift = repoRoot.appendingPathComponent("Package.swift")
        guard let text = try? String(contentsOf: packageSwift, encoding: .utf8) else { return nil }

        if let value = firstCapture(pattern: #"executableTarget\s*\(\s*name:\s*"([^"]+)""#, in: text) {
            return value
        }
        if let value = firstCapture(pattern: #"\.executable\s*\(\s*name:\s*"([^"]+)""#, in: text) {
            return value
        }
        return nil
    }

    private func resolveSwiftPackageExecutablePath(repoRoot: URL, executableName: String?) -> String? {
        let fileManager = FileManager.default
        let debugDirectory = repoRoot.appendingPathComponent(".build/debug", isDirectory: true)

        if let executableName {
            let candidate = debugDirectory.appendingPathComponent(executableName)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: debugDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard item.pathExtension.isEmpty else { continue }
            guard fileManager.isExecutableFile(atPath: item.path) else { continue }
            return item.path
        }
        return nil
    }

    private func assessSwiftPackageGUICapability(repoRoot: URL, executableName: String?) -> SwiftGUICapabilityAssessment {
        let fileManager = FileManager.default
        let sourcesRoot = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        var scanRoots: [URL] = []

        if let executableName {
            let targetRoot = sourcesRoot.appendingPathComponent(executableName, isDirectory: true)
            if fileManager.fileExists(atPath: targetRoot.path) {
                scanRoots.append(targetRoot)
            }
        }
        if scanRoots.isEmpty, fileManager.fileExists(atPath: sourcesRoot.path) {
            scanRoots.append(sourcesRoot)
        }

        let guiImports: [(needle: String, label: String)] = [
            ("import SwiftUI", "SwiftUI"),
            ("import AppKit", "AppKit"),
            ("import Cocoa", "Cocoa"),
            ("import MetalKit", "MetalKit"),
            ("import UIKit", "UIKit")
        ]

        var signals: [String] = []
        var scannedFiles = 0

        for root in scanRoots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles],
                errorHandler: nil
            ) else {
                continue
            }

            while let file = enumerator.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                scannedFiles += 1
                if scannedFiles > 200 { break }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for importSignal in guiImports where text.contains(importSignal.needle) {
                    let relativePath = file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                    signals.append("\(importSignal.label) in \(relativePath)")
                    if signals.count >= 4 { break }
                }
                if signals.count >= 4 { break }
            }
            if scannedFiles > 200 || signals.count >= 4 { break }
        }

        if signals.isEmpty {
            let readmeCandidates = ["README.md", "Readme.md", "readme.md"]
            for name in readmeCandidates {
                let readmeURL = repoRoot.appendingPathComponent(name)
                guard let text = try? String(contentsOf: readmeURL, encoding: .utf8) else { continue }
                let lower = text.lowercased()
                if lower.contains("swiftui") || lower.contains("appkit") || lower.contains("macos app") || lower.contains("window") {
                    signals.append("README indicates macOS GUI usage")
                    break
                }
            }
        }

        return SwiftGUICapabilityAssessment(likelyGUI: !signals.isEmpty, signals: signals)
    }

    private func startNativeExecutable(executablePath: String, workingDirectory: URL) throws -> Process {
        let process = Process()
        process.currentDirectoryURL = workingDirectory
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = []
        try process.run()
        return process
    }

    private func launchNativeExecutableWithAssessment(
        executablePath: String,
        workingDirectory: URL
    ) async -> NativeExecutableLaunchOutcome {
        do {
            let process = try startNativeExecutable(executablePath: executablePath, workingDirectory: workingDirectory)
            try? await Task.sleep(nanoseconds: 900_000_000)
            if process.isRunning {
                return .running(process: process)
            }
            return .exited(code: process.terminationStatus)
        } catch {
            return .failed(message: "Failed to launch native executable: \(error.localizedDescription)")
        }
    }

    private func runProcessCapture(executablePath: String, args: [String], workingDirectory: URL) -> (exitCode: Int32, output: String) {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.currentDirectoryURL = workingDirectory
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, error.localizedDescription)
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let output = (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }

    private func didLaunchedAppRemainRunning(appURL: URL) async -> Bool {
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard let bundle = Bundle(url: appURL),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return true
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        return running.contains { !$0.isTerminated }
    }

    private func handleWebProcessOutputIfNeeded(from text: String) {
        guard launchpadPlan?.outputMode == .webPreview else { return }
        guard let detected = localhostURL(from: text) else { return }

        if launchpadPlannedPreviewURL?.absoluteString != detected.absoluteString {
            launchpadPlannedPreviewURL = detected
        }
        if launchpadLivePreviewURL == nil {
            launchpadWebStartupStatus = "Detected server URL. Waiting for readiness: \(detected.absoluteString)"
        }
    }

    private func startWebReadinessMonitoring() {
        guard launchpadPlan?.outputMode == .webPreview else { return }
        stopWebReadinessMonitoring()

        launchpadWebReadinessTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard self.isRunningLaunchpad else { return }

                if let liveURL = self.launchpadLivePreviewURL {
                    self.launchpadWebStartupStatus = "Preview live: \(liveURL.absoluteString)"
                    return
                }

                if let planned = self.launchpadPlannedPreviewURL {
                    if let port = planned.port {
                        self.launchpadWebStartupStatus = "Waiting for \(planned.host ?? "localhost"):\(port)..."
                    } else {
                        self.launchpadWebStartupStatus = "Waiting for \(planned.absoluteString)..."
                    }
                    if await self.webServerReadinessMonitor.isReachable(url: planned) {
                        self.launchpadLivePreviewURL = planned
                        self.launchpadWebStartupStatus = "Preview live: \(planned.absoluteString)"
                        self.statusMessage = "Localhost preview is live."
                        return
                    }
                } else {
                    self.launchpadWebStartupStatus = "Starting dev server..."
                }

                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private func stopWebReadinessMonitoring() {
        launchpadWebReadinessTask?.cancel()
        launchpadWebReadinessTask = nil
    }

    private func localhostURL(from text: String) -> URL? {
        let fullPattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d{2,5})?(?:/[^\s"']*)?"#
        if let match = firstMatch(pattern: fullPattern, in: text) {
            let normalized = match.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
            if let url = URL(string: normalized) {
                return url
            }
        }

        let portPattern = #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0):(\d{2,5})"#
        if let match = firstMatch(pattern: portPattern, in: text) {
            let rawPort = match.replacingOccurrences(of: "localhost:", with: "")
                .replacingOccurrences(of: "127.0.0.1:", with: "")
                .replacingOccurrences(of: "0.0.0.0:", with: "")
            if let port = Int(rawPort), (1...65535).contains(port) {
                return URL(string: "http://127.0.0.1:\(port)")
            }
        }

        return nil
    }

    private func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, range: nsRange),
              let range = Range(result.range, in: text) else { return nil }
        return String(text[range])
    }

    private func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, range: nsRange),
              result.numberOfRanges > 1,
              let captureRange = Range(result.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    private func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false

        for idx in text.indices[start...] {
            let ch = text[idx]
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if ch == "\"" {
                inString.toggle()
                continue
            }
            if inString {
                continue
            }
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...idx])
                }
            }
        }
        return nil
    }

    private func resolveAppBundlePath(_ path: String, workingDirectory: URL) -> URL? {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return workingDirectory.appendingPathComponent(path).standardizedFileURL
    }

    private func resolveWorkingDirectory(planWorkingDirectory: String, repoRootPath: String) throws -> URL {
        let rootURL = URL(fileURLWithPath: repoRootPath).standardizedFileURL
        let trimmed = planWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)

        let workingURL: URL
        if trimmed.isEmpty || trimmed == "." {
            workingURL = rootURL
        } else if trimmed.hasPrefix("/") {
            workingURL = URL(fileURLWithPath: trimmed).standardizedFileURL
        } else {
            workingURL = rootURL.appendingPathComponent(trimmed).standardizedFileURL
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "RepoAtlas.Launchpad", code: 1, userInfo: [NSLocalizedDescriptionKey: "Working directory does not exist: \(workingURL.path)"])
        }
        guard workingURL.path.hasPrefix(rootURL.path) else {
            throw NSError(domain: "RepoAtlas.Launchpad", code: 2, userInfo: [NSLocalizedDescriptionKey: "Working directory must stay inside the loaded repository."])
        }
        return workingURL
    }

    private func isUnsafe(command: String, args: [String]) -> Bool {
        let joined = ([command] + args).joined(separator: " ").lowercased()
        let blocked = [
            "rm -rf /",
            "sudo ",
            "diskutil erase",
            "mkfs",
            "shutdown",
            "reboot",
            "git reset --hard",
            "git clean -fd"
        ]
        return blocked.contains { joined.contains($0) }
    }

    private func commandDisplay(command: String, args: [String]) -> String {
        ([command] + args).map(quoteIfNeeded).joined(separator: " ")
    }

    private func quoteIfNeeded(_ value: String) -> String {
        guard value.contains(" ") || value.contains("\"") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func isPythonCommand(_ command: String) -> Bool {
        let name = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        return name.hasPrefix("python")
    }
}

private struct WebServerReadinessMonitor {
    func isReachable(url: URL, timeout: TimeInterval = 1.2) async -> Bool {
        guard let probeURL = normalizedProbeURL(from: url) else { return false }
        var request = URLRequest(url: probeURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (100...599).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func normalizedProbeURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = components.host?.lowercased() ?? ""
        if host == "0.0.0.0" {
            components.host = "127.0.0.1"
        }
        if components.scheme == nil {
            components.scheme = "http"
        }
        return components.url
    }
}
