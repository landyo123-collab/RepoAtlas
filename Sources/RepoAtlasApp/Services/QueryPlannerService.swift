import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Query Planner (PADA+ Pre-Retrieval Planning)

/// A cheap, structured, pre-retrieval stage that uses DeepSeek to rewrite vague
/// user questions into repo-specific retrieval plans. The planner does NOT answer
/// the user's question — it only improves retrieval targeting.
///
/// Flow:
///   1. Specificity analyzer decides if planner should run
///   2. Planner input builder creates bounded context package (tree/titles/summaries)
///   3. DeepSeek returns structured JSON retrieval plan
///   4. Validator checks all requested files/dirs/symbols against real repo
///   5. Validated hints feed into PADA+ candidate discovery and governing-file detection

// MARK: - Specificity Analyzer

/// Deterministic analysis of query specificity to decide whether the planner should run.
struct QuerySpecificityAnalyzer {

    struct SpecificityResult {
        /// 0.0 = very vague, 1.0 = very specific
        let score: Double
        let shouldRunPlanner: Bool
        let reasons: [String]
    }

    /// Vague terms that indicate broad/unfocused queries
    private static let vagueTerms: Set<String> = [
        "project", "repo", "repository", "codebase", "looking",
        "overview", "tour", "status", "track", "read", "start",
        "first", "overall", "general", "everything", "whole"
    ]

    private static let vaguePhrases: [String] = [
        "how is this", "how does this look", "what should i",
        "give me a", "is this on track", "current state",
        "what's the status", "how's the", "what is this",
        "tell me about", "walk me through", "show me",
        "what do i need", "where do i start", "how is the"
    ]

    func analyze(queryIntent: QueryIntent, queryLength: Int) -> SpecificityResult {
        var score: Double = 0.5  // start neutral
        var reasons: [String] = []

        // Factor 1: Symbol hints (strong specificity signal)
        let symbolCount = queryIntent.symbolHints.count
        if symbolCount >= 2 {
            score += 0.3
            reasons.append("multiple symbols (\(symbolCount))")
        } else if symbolCount == 1 {
            score += 0.15
            reasons.append("one symbol hint")
        } else {
            score -= 0.15
            reasons.append("no symbol hints")
        }

        // Factor 2: Extracted terms density
        let meaningfulTerms = queryIntent.extractedTerms.filter { $0.count > 3 }
        if meaningfulTerms.count >= 4 {
            score += 0.1
        } else if meaningfulTerms.count <= 1 {
            score -= 0.15
            reasons.append("few meaningful terms (\(meaningfulTerms.count))")
        }

        // Factor 3: Query length (very short = likely vague)
        if queryLength < 25 {
            score -= 0.2
            reasons.append("very short query (\(queryLength) chars)")
        } else if queryLength < 50 {
            score -= 0.1
            reasons.append("short query")
        } else if queryLength > 120 {
            score += 0.1
        }

        // Factor 4: Vague term presence
        let lower = queryIntent.extractedTerms.map { $0.lowercased() }
        let vagueCount = lower.filter { Self.vagueTerms.contains($0) }.count
        if vagueCount >= 2 {
            score -= 0.2
            reasons.append("\(vagueCount) vague terms")
        } else if vagueCount == 1 {
            score -= 0.1
        }

        // Factor 5: Query type (wholeSystem/mixed → more likely to need planner)
        switch queryIntent.primary {
        case .wholeSystem:
            score -= 0.15
            reasons.append("wholeSystem query type")
        case .mixed:
            score -= 0.1
            reasons.append("mixed query type")
        case .architecture:
            if queryIntent.confidence < 0.6 {
                score -= 0.1
                reasons.append("low-confidence architecture")
            }
        case .implementation, .debugging:
            score += 0.1
            if symbolCount > 0 {
                score += 0.1
                reasons.append("targeted \(queryIntent.primary.rawValue) with symbols")
            }
        }

        // Factor 6: Confidence (low classifier confidence = vague)
        if queryIntent.confidence < 0.5 {
            score -= 0.1
            reasons.append("low classifier confidence (\(String(format: "%.2f", queryIntent.confidence)))")
        }

        let clampedScore = max(0.0, min(1.0, score))

        // Planner threshold: run when score < 0.45
        let shouldRun = clampedScore < 0.45

        return SpecificityResult(
            score: clampedScore,
            shouldRunPlanner: shouldRun,
            reasons: reasons
        )
    }
}

// MARK: - Planner Output Models

/// Structured output from the planner. All fields are optional for resilience.
struct PlannerOutput: Codable {
    let plannerVersion: String?
    let rawQuery: String?
    let rewrittenQuery: String?
    let intent: PlannerIntent?
    let whyThisQueryNeedsPlanning: String?
    let governingFilesToInspect: [PlannerFileRequest]?
    let priorityFiles: [PlannerFileRequest]?
    let priorityDirectories: [PlannerDirRequest]?
    let prioritySymbols: [PlannerSymbolRequest]?
    let questionsTheDossierShouldAnswer: [String]?
    let coverageExpectations: [String]?
    let suspectedMissingAreasToVerify: [PlannerMissingArea]?

    enum CodingKeys: String, CodingKey {
        case plannerVersion = "planner_version"
        case rawQuery = "raw_query"
        case rewrittenQuery = "rewritten_query"
        case intent
        case whyThisQueryNeedsPlanning = "why_this_query_needs_planning"
        case governingFilesToInspect = "governing_files_to_inspect"
        case priorityFiles = "priority_files"
        case priorityDirectories = "priority_directories"
        case prioritySymbols = "priority_symbols"
        case questionsTheDossierShouldAnswer = "questions_the_dossier_should_answer"
        case coverageExpectations = "coverage_expectations"
        case suspectedMissingAreasToVerify = "suspected_missing_areas_to_verify"
    }
}

struct PlannerIntent: Codable {
    let primary: String?
    let secondary: [String]?
    let confidence: Double?
}

struct PlannerFileRequest: Codable {
    let path: String
    let reason: String?
    let priority: Double?
}

struct PlannerDirRequest: Codable {
    let path: String
    let reason: String?
    let priority: Double?
}

struct PlannerSymbolRequest: Codable {
    let symbol: String
    let reason: String?
    let priority: Double?
}

struct PlannerMissingArea: Codable {
    let pathOrArea: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case pathOrArea = "path_or_area"
        case reason
    }
}

// MARK: - Validated Planner Hints

/// Planner output after validation against the real repo.
/// Only contains files/dirs/symbols that actually exist.
struct ValidatedPlannerHints {
    let rewrittenQuery: String?
    let additionalTerms: [String]
    let validatedFiles: [(path: String, reason: String, priority: Double)]
    let validatedDirs: [(path: String, reason: String, priority: Double)]
    let validatedSymbols: [(symbol: String, reason: String)]
    let governingFileRequests: [(path: String, reason: String, priority: Double)]
    let dossierSubquestions: [String]
    let coverageExpectations: [String]
    let invalidSuggestions: [(what: String, reason: String)]
    let plannerReason: String?

    /// Score boost applied to planner-suggested candidates
    static let fileBoost: Double = 4.0
    static let dirBoost: Double = 2.5
    static let symbolBoost: Double = 3.0
    static let governingBoost: Double = 5.0
}

// MARK: - Planner Service

struct QueryPlannerService {

    static let plannerVersion = "1"

    // MARK: - Planner Input Building

    /// Build a bounded, cheap context package for the planner.
    /// This sees only structure — no raw file contents.
    static func buildPlannerInput(
        query: String,
        queryIntent: QueryIntent,
        specificity: QuerySpecificityAnalyzer.SpecificityResult,
        store: RepoMemoryStore,
        meta: RepoMeta,
        governingCandidates: [GoverningFileDetector.GoverningFile]
    ) -> String {
        // Repo identity
        let passport = String(meta.passport.prefix(300))
        let topDirs = meta.topLevelDirs.prefix(15).joined(separator: ", ")

        // Governing file candidates
        let govLines: String
        if governingCandidates.isEmpty {
            govLines = "  (none detected yet)"
        } else {
            govLines = governingCandidates.prefix(10).map { gf in
                "  \(gf.path) [\(gf.governingType.rawValue)] priority=\(String(format: "%.1f", gf.priority))"
            }.joined(separator: "\n")
        }

        // Important files: top files by importance + entrypoints + configs + docs
        var keyFiles: [(path: String, type: String, summary: String)] = []
        var seen = Set<String>()

        func addFile(_ f: StoredFile) {
            guard !seen.contains(f.relativePath) else { return }
            seen.insert(f.relativePath)
            keyFiles.append((f.relativePath, f.fileType, String(f.summary.prefix(120))))
        }

        for f in store.topFiles(limit: 12) { addFile(f) }
        for f in store.filesByType("entrypoint").prefix(5) { addFile(f) }
        for f in store.filesByType("config").prefix(5) where f.roleTags.contains("manifest") { addFile(f) }
        for f in store.filesByType("docs").prefix(5) { addFile(f) }

        let fileLines = keyFiles.prefix(25).map { entry in
            "  \(entry.path) | \(entry.type) | \(entry.summary)"
        }.joined(separator: "\n")

        // Subtree summaries
        let subtrees = store.allSubtreeSummaries()
        let subtreeLines = subtrees.prefix(8).map { entry in
            let label = entry.root.isEmpty ? "(root)" : entry.root
            return "  \(label): \(entry.fileCount) files — \(String(entry.summary.prefix(100)))"
        }.joined(separator: "\n")

        // Specificity info
        let specLabel: String
        if specificity.score < 0.3 { specLabel = "very low" }
        else if specificity.score < 0.45 { specLabel = "low" }
        else { specLabel = "medium" }

        return """
        REPOSITORY: \(meta.displayName)
        IDENTITY: \(passport)

        TOP-LEVEL DIRECTORIES: \(topDirs)

        SUBTREES:
        \(subtreeLines)

        GOVERNING FILE CANDIDATES:
        \(govLines)

        KEY FILES (\(keyFiles.count) shown):
        \(fileLines)

        QUERY CLASSIFICATION: \(queryIntent.primary.rawValue) (confidence: \(String(format: "%.2f", queryIntent.confidence)))
        SPECIFICITY: \(specLabel) (\(String(format: "%.2f", specificity.score)))

        USER QUESTION: \(query)
        """
    }

    // MARK: - Planner Prompt

    private static let systemPrompt = """
    You are a RETRIEVAL PLANNER for a code repository Q&A system.
    Your ONLY job is to improve search targeting for the user's question.

    ABSOLUTE RULES:
    1. You must NEVER answer the user's question.
    2. You must NEVER invent facts about the repository beyond what is shown.
    3. You must ONLY return a JSON retrieval plan.
    4. Only request files/directories/symbols that appear plausible from the structure provided.
    5. If the query is already specific enough, keep the rewrite close to the original.
    6. For overview/tour/status queries, prioritize governing files and broad coverage.
    7. For implementation queries, prioritize specific code files and symbols.
    8. For debugging queries, prioritize tests, error paths, and related code.

    Return ONLY valid JSON. No markdown fences. No commentary. No preamble.
    """

    private static let schemaHint = """

    Return JSON matching this schema:
    {
      "planner_version": "1",
      "raw_query": "<the original question>",
      "rewritten_query": "<a more specific, retrieval-friendly version of the question>",
      "intent": {
        "primary": "implementation|architecture|debugging|mixed|wholeSystem|status",
        "secondary": [],
        "confidence": 0.0
      },
      "why_this_query_needs_planning": "<brief reason>",
      "governing_files_to_inspect": [
        {"path": "...", "reason": "...", "priority": 0.0}
      ],
      "priority_files": [
        {"path": "...", "reason": "...", "priority": 0.0}
      ],
      "priority_directories": [
        {"path": "...", "reason": "...", "priority": 0.0}
      ],
      "priority_symbols": [
        {"symbol": "...", "reason": "...", "priority": 0.0}
      ],
      "questions_the_dossier_should_answer": ["..."],
      "coverage_expectations": ["governing_files","major_zones","status"],
      "suspected_missing_areas_to_verify": [
        {"path_or_area": "...", "reason": "..."}
      ]
    }
    """

    // MARK: - DeepSeek Call

    /// Call DeepSeek as a retrieval planner. Returns raw PlannerOutput or nil on failure.
    static func callPlanner(
        plannerInput: String,
        configuration: DeepSeekConfiguration
    ) async -> (output: PlannerOutput?, rawJSON: String?, error: String?) {
        guard configuration.isConfigured else {
            return (nil, nil, "DeepSeek not configured")
        }

        let trimmedBase = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedBase + "/chat/completions") else {
            return (nil, nil, "Invalid DeepSeek base URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30  // bounded — planner should be fast

        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "deepseek-chat" : configuration.model

        struct Msg: Codable { let role: String; let content: String }
        struct Req: Codable { let model: String; let messages: [Msg]; let temperature: Double; let stream: Bool; let max_tokens: Int }
        struct Choice: Codable { let message: Msg }
        struct Resp: Codable { let choices: [Choice] }

        let payload = Req(
            model: model,
            messages: [
                Msg(role: "system", content: systemPrompt),
                Msg(role: "user", content: plannerInput + schemaHint)
            ],
            temperature: 0.15,
            stream: false,
            max_tokens: 1500
        )

        do {
            let body = try JSONEncoder().encode(payload)
            request.httpBody = body

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let msg = String(data: data, encoding: .utf8) ?? "unknown"
                return (nil, nil, "DeepSeek planner HTTP \(status): \(String(msg.prefix(200)))")
            }

            guard let resp = try? JSONDecoder().decode(Resp.self, from: data),
                  let content = resp.choices.first?.message.content else {
                return (nil, nil, "DeepSeek planner returned no content")
            }

            // Strip markdown code fences if present
            let cleaned = cleanJSON(content)

            guard let jsonData = cleaned.data(using: .utf8) else {
                return (nil, cleaned, "Cannot encode planner response as UTF-8")
            }

            let decoder = JSONDecoder()
            do {
                let output = try decoder.decode(PlannerOutput.self, from: jsonData)
                return (output, cleaned, nil)
            } catch {
                return (nil, cleaned, "JSON decode error: \(error.localizedDescription)")
            }
        } catch {
            return (nil, nil, "Planner call failed: \(error.localizedDescription)")
        }
    }

    /// Strip markdown code fences and trim whitespace from DeepSeek response.
    private static func cleanJSON(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```json") {
            s = String(s.dropFirst(7))
        } else if s.hasPrefix("```") {
            s = String(s.dropFirst(3))
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Validation

    /// Validate planner output against the real repo.
    /// Drops invalid file/dir/symbol suggestions and records them.
    static func validate(
        output: PlannerOutput,
        store: RepoMemoryStore,
        queryIntent: QueryIntent
    ) -> ValidatedPlannerHints {
        var validatedFiles: [(path: String, reason: String, priority: Double)] = []
        var validatedDirs: [(path: String, reason: String, priority: Double)] = []
        var validatedSymbols: [(symbol: String, reason: String)] = []
        var governingFileRequests: [(path: String, reason: String, priority: Double)] = []
        var invalidSuggestions: [(what: String, reason: String)] = []

        // Validate governing files
        for gf in output.governingFilesToInspect ?? [] {
            let path = gf.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            if let _ = store.file(byPath: path) {
                governingFileRequests.append((path, gf.reason ?? "", gf.priority ?? 5.0))
            } else {
                invalidSuggestions.append(("governing:\(path)", "file not found in repo"))
            }
        }

        // Validate priority files
        for pf in output.priorityFiles ?? [] {
            let path = pf.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            if let _ = store.file(byPath: path) {
                validatedFiles.append((path, pf.reason ?? "", pf.priority ?? 3.0))
            } else {
                invalidSuggestions.append(("file:\(path)", "file not found in repo"))
            }
        }

        // Validate priority directories (check if any files exist under this path)
        for pd in output.priorityDirectories ?? [] {
            let path = pd.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let filesInDir = store.searchFiles(query: path, limit: 3)
            if !filesInDir.isEmpty {
                validatedDirs.append((path, pd.reason ?? "", pd.priority ?? 2.0))
            } else {
                // Check subtree summaries as fallback
                let subtrees = store.allSubtreeSummaries()
                let hasSubtree = subtrees.contains { $0.root == path || $0.root.hasPrefix(path) || path.hasPrefix($0.root) }
                if hasSubtree {
                    validatedDirs.append((path, pd.reason ?? "", pd.priority ?? 2.0))
                } else {
                    invalidSuggestions.append(("dir:\(path)", "directory not found in repo"))
                }
            }
        }

        // Validate priority symbols
        for ps in output.prioritySymbols ?? [] {
            let sym = ps.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sym.isEmpty else { continue }
            let symMatches = store.searchSymbols(query: sym, limit: 3)
            if !symMatches.isEmpty {
                validatedSymbols.append((sym, ps.reason ?? ""))
            } else {
                invalidSuggestions.append(("symbol:\(sym)", "symbol not found in repo"))
            }
        }

        // Extract additional search terms from rewritten query
        let classifier = QueryPolicyClassifier()
        let additionalTerms: [String]
        if let rewritten = output.rewrittenQuery, !rewritten.isEmpty {
            let rewrittenTerms = classifier.extractTerms(from: rewritten)
            let originalTerms = Set(queryIntent.extractedTerms)
            additionalTerms = rewrittenTerms.filter { !originalTerms.contains($0) }
        } else {
            additionalTerms = []
        }

        return ValidatedPlannerHints(
            rewrittenQuery: output.rewrittenQuery,
            additionalTerms: Array(additionalTerms.prefix(10)),
            validatedFiles: validatedFiles,
            validatedDirs: validatedDirs,
            validatedSymbols: validatedSymbols,
            governingFileRequests: governingFileRequests,
            dossierSubquestions: output.questionsTheDossierShouldAnswer ?? [],
            coverageExpectations: output.coverageExpectations ?? [],
            invalidSuggestions: invalidSuggestions,
            plannerReason: output.whyThisQueryNeedsPlanning
        )
    }
}

// MARK: - Planner Cache

/// Caches validated planner output to avoid re-running the planner for identical queries.
struct PlannerCache {

    private let cacheDir: String

    init(repoRoot: String) {
        self.cacheDir = (repoRoot as NSString).appendingPathComponent(".repoatlas/planner_cache")
    }

    struct CachedPlan: Codable {
        let cacheKey: String
        let repoHash: String
        let plannerVersion: String
        let createdAt: Date
        let rewrittenQuery: String?
        let additionalTerms: [String]
        let validatedFilePaths: [String]
        let validatedDirPaths: [String]
        let validatedSymbols: [String]
        let governingFilePaths: [String]
        let dossierSubquestions: [String]
        let coverageExpectations: [String]
        let plannerReason: String?
    }

    func lookup(query: String, repoHash: String) -> CachedPlan? {
        let key = cacheKey(query: query, repoHash: repoHash)
        let path = cachePath(for: key)

        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entry = try? decoder.decode(CachedPlan.self, from: data) else { return nil }

        guard entry.plannerVersion == QueryPlannerService.plannerVersion,
              entry.repoHash == repoHash else {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }

        // Expire after 12 hours
        if Date().timeIntervalSince(entry.createdAt) > 43_200 {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }

        return entry
    }

    func store(hints: ValidatedPlannerHints, query: String, repoHash: String) {
        let key = cacheKey(query: query, repoHash: repoHash)
        let path = cachePath(for: key)

        let entry = CachedPlan(
            cacheKey: key,
            repoHash: repoHash,
            plannerVersion: QueryPlannerService.plannerVersion,
            createdAt: Date(),
            rewrittenQuery: hints.rewrittenQuery,
            additionalTerms: hints.additionalTerms,
            validatedFilePaths: hints.validatedFiles.map(\.path),
            validatedDirPaths: hints.validatedDirs.map(\.path),
            validatedSymbols: hints.validatedSymbols.map(\.symbol),
            governingFilePaths: hints.governingFileRequests.map(\.path),
            dossierSubquestions: hints.dossierSubquestions,
            coverageExpectations: hints.coverageExpectations,
            plannerReason: hints.plannerReason
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entry) else { return }

        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: data)
    }

    private func cacheKey(query: String, repoHash: String) -> String {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = "planner-v\(QueryPlannerService.plannerVersion)|\(repoHash)|\(normalized)"
        return raw.sha256Hex
    }

    private func cachePath(for key: String) -> String {
        (cacheDir as NSString).appendingPathComponent("\(key).json")
    }
}

// MARK: - Planner Metadata (for dossier diagnostics)

struct PlannerMetadata: Codable {
    let plannerRan: Bool
    let plannerSkipReason: String?
    let specificityScore: Double
    let rewrittenQuery: String?
    let validatedFileCount: Int
    let validatedDirCount: Int
    let validatedSymbolCount: Int
    let governingFileRequestCount: Int
    let invalidSuggestionCount: Int
    let dossierSubquestions: [String]
    let plannerCacheHit: Bool
    let plannerError: String?
    let plannerReason: String?

    enum CodingKeys: String, CodingKey {
        case plannerRan = "planner_ran"
        case plannerSkipReason = "planner_skip_reason"
        case specificityScore = "specificity_score"
        case rewrittenQuery = "rewritten_query"
        case validatedFileCount = "validated_file_count"
        case validatedDirCount = "validated_dir_count"
        case validatedSymbolCount = "validated_symbol_count"
        case governingFileRequestCount = "governing_file_request_count"
        case invalidSuggestionCount = "invalid_suggestion_count"
        case dossierSubquestions = "dossier_subquestions"
        case plannerCacheHit = "planner_cache_hit"
        case plannerError = "planner_error"
        case plannerReason = "planner_reason"
    }

    static let skipped = PlannerMetadata(
        plannerRan: false, plannerSkipReason: "high specificity",
        specificityScore: 1.0, rewrittenQuery: nil,
        validatedFileCount: 0, validatedDirCount: 0,
        validatedSymbolCount: 0, governingFileRequestCount: 0,
        invalidSuggestionCount: 0, dossierSubquestions: [],
        plannerCacheHit: false, plannerError: nil, plannerReason: nil
    )
}
