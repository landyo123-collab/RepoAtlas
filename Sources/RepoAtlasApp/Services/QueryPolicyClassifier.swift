import Foundation

// MARK: - PADA+ Deterministic Query Policy Classifier

/// Classifies queries into types and produces retrieval policies WITHOUT any LLM call.
/// Uses keyword patterns, symbol detection, and structural heuristics.
///
/// v2: Improved wholeSystem vs architecture separation, stronger debugging signals,
///     borderline-policy blending when top two types are close.
struct QueryPolicyClassifier {

    /// Classify a query and return both intent and retrieval policy.
    func classify(query: String, repoFileCount: Int) -> (intent: QueryIntent, policy: QueryPolicy) {
        let lower = query.lowercased()
        let terms = extractTerms(from: query)
        let symbols = extractSymbolHints(from: query)

        let scores = computeTypeScores(lower: lower, terms: terms, symbols: symbols)

        // Sort scores descending to find primary and runner-up
        let sorted = scores.sorted { $0.value > $1.value }
        let primary = sorted.first?.key ?? .mixed
        let primaryScore = sorted.first?.value ?? 0
        let runnerUp = sorted.count > 1 ? sorted[1].key : nil
        let runnerUpScore = sorted.count > 1 ? sorted[1].value : 0

        let confidence = computeConfidence(scores: scores, primary: primary)

        // Secondary intents: any type scoring above 0.3 that isn't primary
        let secondary = scores.filter { $0.key != primary && $0.value > 0.3 }
            .sorted { $0.value > $1.value }
            .map(\.key)

        let intent = QueryIntent(
            primary: primary,
            secondary: secondary,
            confidence: confidence,
            extractedTerms: terms,
            symbolHints: symbols
        )

        // Build policy with borderline blending
        let policy = buildPolicy(
            queryType: primary,
            runnerUp: runnerUp,
            primaryScore: primaryScore,
            runnerUpScore: runnerUpScore,
            repoFileCount: repoFileCount,
            hasSymbols: !symbols.isEmpty
        )
        return (intent, policy)
    }

    // MARK: - Type scoring

    private func computeTypeScores(lower: String, terms: [String], symbols: [String]) -> [QueryType: Double] {
        var scores: [QueryType: Double] = [
            .implementation: 0,
            .architecture: 0,
            .debugging: 0,
            .wholeSystem: 0,
            .mixed: 0
        ]

        // Implementation signals
        let implKeywords: Set<String> = [
            "implement", "implementation", "function", "method",
            "class", "struct", "protocol", "called", "calls", "invokes", "uses",
            "flow", "pipeline", "handler", "execute", "run", "process",
            "code", "logic", "algorithm", "compute", "calculate"
        ]
        let implPhrases = [
            "how does", "how is", "where is", "where does", "what does",
            "how are", "which file", "which function", "what function",
            "implementation of", "defined in", "called from", "calls to"
        ]
        for term in terms where implKeywords.contains(term) {
            scores[.implementation, default: 0] += 1.0
        }
        for phrase in implPhrases where lower.contains(phrase) {
            scores[.implementation, default: 0] += 1.5
        }
        // Symbols indicate implementation queries, but with a cap so debugging/wholeSystem
        // can still win when their signals are strong
        if !symbols.isEmpty {
            scores[.implementation, default: 0] += min(Double(min(symbols.count, 3)) * 1.5, 4.5)
        }

        // Architecture signals
        let archKeywords: Set<String> = [
            "structure", "structured", "architecture", "design", "pattern",
            "organization", "organized", "layout", "module",
            "modules", "layer", "layers",
            "dependency", "dependencies", "relationship", "zone", "zones",
            "subsystem", "subsystems", "separation", "coupling"
        ]
        let archPhrases = [
            "repo structured", "codebase structure",
            "major zone", "high-level", "big picture", "bird's eye",
            "project structure", "folder structure", "directory structure",
            "how is this organized", "how is this structured"
        ]
        for term in terms where archKeywords.contains(term) {
            scores[.architecture, default: 0] += 1.0
        }
        for phrase in archPhrases where lower.contains(phrase) {
            scores[.architecture, default: 0] += 1.5
        }

        // Debugging signals (v2: expanded significantly)
        let debugKeywords: Set<String> = [
            "error", "bug", "fail", "fails", "failure", "failing", "crash", "exception",
            "wrong", "broken", "fix", "issue", "problem", "debug",
            "trace", "stack", "stacktrace", "panic", "abort", "nil",
            "null", "undefined", "timeout", "deadlock", "race",
            "regression", "assertion", "assert", "flaky", "intermittent",
            "unexpected", "incorrect", "invalid", "corrupt"
        ]
        let debugPhrases = [
            "why does", "why is", "why might", "why would", "why could",
            "what causes", "root cause",
            "doesn't work", "not working", "throwing", "crashing",
            "tests fail", "test fail", "failing test", "failing path",
            "test coverage", "test broken", "tests broken",
            "might fail", "could fail", "would fail",
            "error handling", "error handler"
        ]
        for term in terms where debugKeywords.contains(term) {
            scores[.debugging, default: 0] += 1.2
        }
        for phrase in debugPhrases where lower.contains(phrase) {
            scores[.debugging, default: 0] += 2.0
        }

        // Debug boost: if query mentions tests alongside failure/problem words,
        // that's a strong debugging signal even if "test" alone isn't debug-specific
        let hasTestWord = lower.contains("test")
        let hasFailureContext = debugKeywords.contains(where: { lower.contains($0) })
        if hasTestWord && hasFailureContext {
            scores[.debugging, default: 0] += 2.5
        }

        // Whole-system signals (v2: expanded with keywords AND phrases,
        // and stronger scoring to beat architecture on borderline queries)
        let wholeKeywords: Set<String> = [
            "tour", "overview", "summarize", "summary", "onboard",
            "onboarding", "walkthrough", "map", "readme", "status",
            "looking", "track"
        ]
        let wholePhrases = [
            "give me a tour", "repo tour", "codebase tour",
            "what does this repo", "what does this project",
            "explain the repo", "explain this repo", "explain the project",
            "what should i read", "where should i start",
            "entry point", "entry points", "getting started",
            "main component", "main components", "major component", "major components",
            "major part", "major parts", "main part", "main parts",
            "end-to-end", "end to end", "whole repo", "whole codebase",
            "how does this repo work", "how does this project work",
            "what is this repo", "what is this project",
            "how is this project", "is this on track",
            "current state", "project looking", "how's the project",
            "state of this repo", "state of this project"
        ]
        for term in terms where wholeKeywords.contains(term) {
            scores[.wholeSystem, default: 0] += 2.0
        }
        for phrase in wholePhrases where lower.contains(phrase) {
            scores[.wholeSystem, default: 0] += 2.5
        }

        // Disambiguation: "what are the" is ambiguous — only boost architecture
        // if there are OTHER architecture signals already present
        if lower.contains("what are the") {
            let hasArchContext = scores[.architecture, default: 0] > 0
            if hasArchContext {
                scores[.architecture, default: 0] += 1.0
            } else {
                // Without other arch signals, "what are the main X" is more wholeSystem
                scores[.wholeSystem, default: 0] += 1.0
            }
        }

        // Disambiguation: "component(s)" is shared between arch and wholeSystem.
        // Only count for architecture if there are other arch-specific signals.
        let componentInQuery = lower.contains("component") || lower.contains("components")
        if componentInQuery {
            let hasArchSpecificSignal = scores[.architecture, default: 0] > 0
            if hasArchSpecificSignal {
                scores[.architecture, default: 0] += 1.0
            } else {
                // Standalone "components" in a tour-like query → wholeSystem
                scores[.wholeSystem, default: 0] += 1.0
            }
        }

        // If no strong signal, mark as mixed
        let maxScore = scores.values.max() ?? 0
        if maxScore < 1.0 {
            scores[.mixed] = 1.0
        }

        return scores
    }

    private func computeConfidence(scores: [QueryType: Double], primary: QueryType) -> Double {
        let primaryScore = scores[primary] ?? 0
        let totalScore = scores.values.reduce(0, +)
        guard totalScore > 0 else { return 0.5 }

        let dominance = primaryScore / totalScore
        // High dominance = high confidence; low = ambiguous
        return min(1.0, max(0.3, dominance * 1.2))
    }

    // MARK: - Policy construction with borderline blending

    /// If the runner-up type is within 30% of the primary's score, blend policy fields
    /// from the runner-up to reduce damage from borderline misclassification.
    private func buildPolicy(
        queryType: QueryType,
        runnerUp: QueryType?,
        primaryScore: Double,
        runnerUpScore: Double,
        repoFileCount: Int,
        hasSymbols: Bool
    ) -> QueryPolicy {
        let base = basePolicy(queryType: queryType, repoFileCount: repoFileCount, hasSymbols: hasSymbols)

        // Check if borderline: runner-up within 30% of primary score
        guard let runnerUp = runnerUp,
              primaryScore > 0,
              runnerUpScore / primaryScore >= 0.7 else {
            return base
        }

        // Apply blending rules for specific borderline pairs
        return blendPolicy(base: base, primary: queryType, runnerUp: runnerUp, repoFileCount: repoFileCount, hasSymbols: hasSymbols)
    }

    /// Blend policy fields when two types are close. The primary type keeps its core
    /// identity but adopts specific fields from the runner-up to hedge.
    private func blendPolicy(
        base: QueryPolicy,
        primary: QueryType,
        runnerUp: QueryType,
        repoFileCount: Int,
        hasSymbols: Bool
    ) -> QueryPolicy {

        switch (primary, runnerUp) {

        // wholeSystem near architecture: widen breadth, keep docs
        case (.wholeSystem, .architecture), (.architecture, .wholeSystem):
            return QueryPolicy(
                queryType: primary,
                graphHops: 1,
                maxFiles: min(180, repoFileCount),
                maxSegmentsPerFile: 5,
                maxTotalSegments: 280,
                tokenBudget: 96_000,
                preferredFileTypes: ["source", "config", "docs", "entrypoint"],
                preferredTiers: ["firstParty", "projectSupport"],
                includeTests: false,
                includeDocs: true,
                symbolTraversalDepth: 0
            )

        // debugging near implementation: force tests, keep impl depth
        case (.debugging, .implementation), (.implementation, .debugging):
            return QueryPolicy(
                queryType: primary,
                graphHops: 3,
                maxFiles: 75,
                maxSegmentsPerFile: hasSymbols ? 9 : 6,
                maxTotalSegments: 190,
                tokenBudget: 64_000,
                preferredFileTypes: ["source", "test", "entrypoint"],
                preferredTiers: ["firstParty"],
                includeTests: true,      // always include tests for this borderline
                includeDocs: false,
                symbolTraversalDepth: hasSymbols ? 3 : 2
            )

        // architecture near implementation: include some code depth
        case (.architecture, .implementation), (.implementation, .architecture):
            return QueryPolicy(
                queryType: primary,
                graphHops: 2,
                maxFiles: 100,
                maxSegmentsPerFile: 5,
                maxTotalSegments: 200,
                tokenBudget: 72_000,
                preferredFileTypes: ["source", "config", "docs", "entrypoint"],
                preferredTiers: ["firstParty", "projectSupport"],
                includeTests: false,
                includeDocs: true,
                symbolTraversalDepth: hasSymbols ? 2 : 1
            )

        // Any other borderline pair: use the base policy unchanged
        default:
            return base
        }
    }

    private func basePolicy(queryType: QueryType, repoFileCount: Int, hasSymbols: Bool) -> QueryPolicy {
        switch queryType {
        case .implementation:
            return QueryPolicy(
                queryType: .implementation,
                graphHops: hasSymbols ? 3 : 2,
                maxFiles: 80,
                maxSegmentsPerFile: hasSymbols ? 10 : 6,
                maxTotalSegments: 200,
                tokenBudget: 64_000,
                preferredFileTypes: ["source", "entrypoint"],
                preferredTiers: ["firstParty"],
                includeTests: false,
                includeDocs: false,
                symbolTraversalDepth: hasSymbols ? 3 : 1
            )

        case .architecture:
            return QueryPolicy(
                queryType: .architecture,
                graphHops: 1,
                maxFiles: min(150, repoFileCount),
                maxSegmentsPerFile: 5,
                maxTotalSegments: 250,
                tokenBudget: 90_000,
                preferredFileTypes: ["source", "config", "docs", "entrypoint"],
                preferredTiers: ["firstParty", "projectSupport"],
                includeTests: false,
                includeDocs: true,
                symbolTraversalDepth: 0
            )

        case .debugging:
            return QueryPolicy(
                queryType: .debugging,
                graphHops: 3,
                maxFiles: 70,
                maxSegmentsPerFile: 8,
                maxTotalSegments: 180,
                tokenBudget: 60_000,
                preferredFileTypes: ["source", "test", "entrypoint"],
                preferredTiers: ["firstParty"],
                includeTests: true,
                includeDocs: false,
                symbolTraversalDepth: 2
            )

        case .wholeSystem:
            return QueryPolicy(
                queryType: .wholeSystem,
                graphHops: 1,
                maxFiles: min(200, repoFileCount),
                maxSegmentsPerFile: 4,
                maxTotalSegments: 300,
                tokenBudget: 100_000,
                preferredFileTypes: ["source", "config", "docs", "entrypoint"],
                preferredTiers: ["firstParty", "projectSupport"],
                includeTests: false,
                includeDocs: true,
                symbolTraversalDepth: 0
            )

        case .mixed:
            return QueryPolicy(
                queryType: .mixed,
                graphHops: 2,
                maxFiles: 80,
                maxSegmentsPerFile: 5,
                maxTotalSegments: 180,
                tokenBudget: 64_000,
                preferredFileTypes: ["source", "entrypoint", "config"],
                preferredTiers: ["firstParty"],
                includeTests: false,
                includeDocs: true,
                symbolTraversalDepth: 1
            )
        }
    }

    // MARK: - Term extraction

    /// Extract meaningful search terms from the query.
    func extractTerms(from query: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "the", "is", "are", "was", "were", "been", "be",
            "have", "has", "had", "do", "does", "did", "will", "would",
            "could", "should", "may", "might", "shall", "can",
            "i", "me", "my", "we", "our", "you", "your", "it", "its",
            "this", "that", "these", "those", "what", "which", "who",
            "how", "when", "where", "why", "if", "then", "else",
            "and", "or", "but", "not", "no", "nor", "so", "yet",
            "in", "on", "at", "to", "for", "of", "with", "by", "from",
            "up", "about", "into", "through", "during", "before", "after",
            "above", "below", "between", "out", "off", "over", "under",
            "again", "further", "once", "here", "there", "all", "each",
            "every", "both", "few", "more", "most", "other", "some",
            "such", "only", "own", "same", "than", "too", "very",
            "just", "also", "like", "give", "tell", "show", "explain",
            "please", "help", "need", "want", "get", "look", "find",
            "know", "think", "see", "make", "take", "come", "go"
        ]

        return query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "." })
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    /// Extract symbol-like tokens: CamelCase identifiers, snake_case names, dotted paths.
    func extractSymbolHints(from query: String) -> [String] {
        var symbols: [String] = []

        // CamelCase pattern (at least two segments, e.g. "RepoStore", "buildDossier")
        let camelPattern = try? NSRegularExpression(pattern: "\\b[A-Z][a-z]+(?:[A-Z][a-z]+)+\\b")
        if let matches = camelPattern?.matches(in: query, range: NSRange(query.startIndex..., in: query)) {
            for match in matches {
                if let range = Range(match.range, in: query) {
                    symbols.append(String(query[range]))
                }
            }
        }

        // lowerCamelCase (e.g. "buildDossier", "askQuestion")
        let lowerCamelPattern = try? NSRegularExpression(pattern: "\\b[a-z]+[A-Z][a-z]+(?:[A-Z][a-z]+)*\\b")
        if let matches = lowerCamelPattern?.matches(in: query, range: NSRange(query.startIndex..., in: query)) {
            for match in matches {
                if let range = Range(match.range, in: query) {
                    symbols.append(String(query[range]))
                }
            }
        }

        // snake_case with underscores (e.g. "build_dossier")
        let snakePattern = try? NSRegularExpression(pattern: "\\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\\b")
        if let matches = snakePattern?.matches(in: query, range: NSRange(query.startIndex..., in: query)) {
            for match in matches {
                if let range = Range(match.range, in: query) {
                    symbols.append(String(query[range]))
                }
            }
        }

        // Dotted paths (e.g. "RepoStore.ask", "services.EvidenceBuilder")
        let dottedPattern = try? NSRegularExpression(pattern: "\\b[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)+\\b")
        if let matches = dottedPattern?.matches(in: query, range: NSRange(query.startIndex..., in: query)) {
            for match in matches {
                if let range = Range(match.range, in: query) {
                    symbols.append(String(query[range]))
                }
            }
        }

        // File paths (containing / or ending in common extensions)
        let filePattern = try? NSRegularExpression(pattern: "\\b[A-Za-z_][A-Za-z0-9_/]*\\.[a-z]{1,5}\\b")
        if let matches = filePattern?.matches(in: query, range: NSRange(query.startIndex..., in: query)) {
            for match in matches {
                if let range = Range(match.range, in: query) {
                    symbols.append(String(query[range]))
                }
            }
        }

        return Array(Set(symbols))
    }
}
