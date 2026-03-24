import Foundation

// MARK: - Evidence Evaluation Harness (PADA+ Priority 4)

/// Evaluation framework for testing evidence builder quality.
/// Defines named test cases with expected files/zones, runs the builder,
/// and compares against expectations with coverage and precision metrics.
struct EvidenceEvalHarness {

    struct EvalCase {
        let name: String
        let query: String
        /// Files that MUST appear in evidence (paths or path suffixes)
        let expectedFiles: [String]
        /// Files that SHOULD appear (partial match on path)
        let expectedZones: [String]
        /// Query type we expect the classifier to produce
        let expectedQueryType: QueryType
        /// Minimum acceptable coverage (0-1)
        let minCoverage: Double
    }

    struct EvalResult {
        let caseName: String
        let query: String
        let classifiedType: QueryType
        let typeCorrect: Bool
        let expectedFileHits: Int
        let expectedFileTotal: Int
        let expectedZoneHits: Int
        let expectedZoneTotal: Int
        let filePrecision: Double
        let fileRecall: Double
        let zoneRecall: Double
        let totalEvidence: Int
        let totalTokens: Int
        let elapsedMs: Int
        let passed: Bool
        let notes: String
        let governingFileCount: Int
        let governingAnchored: Int
        let governingEvidenceCount: Int
        let plannerWouldRun: Bool
        let specificityScore: Double
    }

    struct EvalSummary {
        let results: [EvalResult]
        let totalCases: Int
        let passedCases: Int
        let avgFileRecall: Double
        let avgZoneRecall: Double
        let avgPrecision: Double
    }

    // MARK: - Built-in Test Cases

    /// Default test cases that work with any repo.
    static func defaultCases() -> [EvalCase] {
        [
            EvalCase(
                name: "repo_overview",
                query: "Give me a tour of this repository. What are the main components?",
                expectedFiles: [],
                expectedZones: [],
                expectedQueryType: .wholeSystem,
                minCoverage: 0.3
            ),
            EvalCase(
                name: "architecture",
                query: "How is this codebase structured? What are the major modules?",
                expectedFiles: [],
                expectedZones: [],
                expectedQueryType: .architecture,
                minCoverage: 0.3
            ),
            EvalCase(
                name: "entry_point",
                query: "Where is the main entry point? How does execution start?",
                expectedFiles: [],
                expectedZones: [],
                expectedQueryType: .implementation,
                minCoverage: 0.3
            ),
            // WholeSystem regression cases for governing file coverage
            EvalCase(
                name: "whole_system_map",
                query: "Summarize the entire project. What is its purpose and how is it organized?",
                expectedFiles: [],
                expectedZones: [],
                expectedQueryType: .wholeSystem,
                minCoverage: 0.3
            ),
            EvalCase(
                name: "whole_system_status",
                query: "What is the current status of this project? What has changed recently?",
                expectedFiles: [],
                expectedZones: [],
                expectedQueryType: .wholeSystem,
                minCoverage: 0.3
            ),
            EvalCase(
                name: "architecture_blueprint",
                query: "Explain the design philosophy and architectural patterns used in this codebase.",
                expectedFiles: [],
                expectedZones: [],
                expectedQueryType: .architecture,
                minCoverage: 0.3
            )
        ]
    }

    /// Build repo-specific test cases from repo memory (symbol-aware).
    static func repoCases(store: RepoMemoryStore) -> [EvalCase] {
        var cases: [EvalCase] = []

        // Find top symbols and build implementation queries
        let topFiles = store.topFiles(limit: 5)
        for file in topFiles.prefix(3) {
            let symbols = store.symbols(forFileId: file.id)
            guard let firstSym = symbols.first else { continue }

            cases.append(EvalCase(
                name: "impl_\(firstSym.name)",
                query: "How does \(firstSym.name) work? Where is it implemented?",
                expectedFiles: [file.relativePath],
                expectedZones: [(file.relativePath as NSString).deletingLastPathComponent],
                expectedQueryType: .implementation,
                minCoverage: 0.5
            ))
        }

        // Find test files and build debugging query
        let testFiles = store.filesByType("test")
        if let testFile = testFiles.first {
            let testDir = (testFile.relativePath as NSString).deletingLastPathComponent
            cases.append(EvalCase(
                name: "debug_tests",
                query: "Why might tests in \(testDir) fail? What do they test?",
                expectedFiles: [testFile.relativePath],
                expectedZones: [testDir],
                expectedQueryType: .debugging,
                minCoverage: 0.4
            ))
        }

        return cases
    }

    // MARK: - Evaluation Execution

    /// Run evaluation against a built dossier (no async needed — evaluates a pre-built dossier).
    func evaluate(dossier: EvidenceDossier, evalCase: EvalCase) -> EvalResult {
        let start = CFAbsoluteTimeGetCurrent()

        // Check query type classification
        let typeCorrect = dossier.queryIntent.primary == evalCase.expectedQueryType

        // Check file hits
        let evidencePaths = Set(dossier.exactEvidence.map(\.path) + dossier.mustReadFiles.map(\.path))
        var expectedFileHits = 0
        for expected in evalCase.expectedFiles {
            let found = evidencePaths.contains(where: { $0.hasSuffix(expected) || $0 == expected })
            if found { expectedFileHits += 1 }
        }

        // Check zone hits (any evidence file in the expected zone)
        var expectedZoneHits = 0
        for zone in evalCase.expectedZones {
            let found = evidencePaths.contains(where: { $0.hasPrefix(zone) || $0.contains(zone) })
            if found { expectedZoneHits += 1 }
        }

        let fileRecall = evalCase.expectedFiles.isEmpty ? 1.0 : Double(expectedFileHits) / Double(evalCase.expectedFiles.count)
        let zoneRecall = evalCase.expectedZones.isEmpty ? 1.0 : Double(expectedZoneHits) / Double(evalCase.expectedZones.count)

        // Precision: what fraction of evidence files are in expected files/zones
        let relevantPaths = Set(evalCase.expectedFiles + evalCase.expectedZones)
        let precisionHits: Int
        if relevantPaths.isEmpty {
            precisionHits = evidencePaths.count  // no expectations → all count
        } else {
            precisionHits = evidencePaths.filter { path in
                relevantPaths.contains(where: { path.hasSuffix($0) || path.hasPrefix($0) || path.contains($0) })
            }.count
        }
        let filePrecision = evidencePaths.isEmpty ? 0.0 : Double(precisionHits) / Double(evidencePaths.count)

        let totalTokens = dossier.builderDiagnostics.dossierTokenEstimate
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

        let overallCoverage = (fileRecall + zoneRecall) / 2.0
        let passed = typeCorrect && overallCoverage >= evalCase.minCoverage

        // Governing file metrics
        let govFileCount = dossier.governingFiles.count
        let govAnchored = dossier.governingFiles.filter(\.anchored).count
        let govEvidenceCount = dossier.exactEvidence.filter { ev in
            ev.provenance.contains { $0.source == .governing }
        }.count

        var notes: [String] = []
        if !typeCorrect {
            notes.append("type: expected \(evalCase.expectedQueryType.rawValue) got \(dossier.queryIntent.primary.rawValue)")
        }
        if fileRecall < evalCase.minCoverage {
            notes.append("file recall \(String(format: "%.0f%%", fileRecall * 100)) < \(String(format: "%.0f%%", evalCase.minCoverage * 100))")
        }
        if !dossier.coverageReport.gaps.isEmpty {
            notes.append("\(dossier.coverageReport.gaps.count) coverage gaps")
        }
        if govFileCount > 0 {
            notes.append("governing: \(govAnchored)/\(govFileCount) anchored, \(govEvidenceCount) evidence segs")
        }

        // Planner metrics
        let plannerWouldRun = dossier.plannerMetadata?.plannerRan ?? false
            || (dossier.plannerMetadata?.specificityScore ?? 1.0) < 0.45
        let specScore = dossier.plannerMetadata?.specificityScore ?? 1.0
        if plannerWouldRun {
            notes.append("planner: would run (specificity \(String(format: "%.2f", specScore)))")
        }

        return EvalResult(
            caseName: evalCase.name,
            query: evalCase.query,
            classifiedType: dossier.queryIntent.primary,
            typeCorrect: typeCorrect,
            expectedFileHits: expectedFileHits,
            expectedFileTotal: evalCase.expectedFiles.count,
            expectedZoneHits: expectedZoneHits,
            expectedZoneTotal: evalCase.expectedZones.count,
            filePrecision: filePrecision,
            fileRecall: fileRecall,
            zoneRecall: zoneRecall,
            totalEvidence: dossier.exactEvidence.count,
            totalTokens: totalTokens,
            elapsedMs: elapsedMs,
            passed: passed,
            notes: notes.joined(separator: "; "),
            governingFileCount: govFileCount,
            governingAnchored: govAnchored,
            governingEvidenceCount: govEvidenceCount,
            plannerWouldRun: plannerWouldRun,
            specificityScore: specScore
        )
    }

    /// Summarize multiple eval results.
    func summarize(results: [EvalResult]) -> EvalSummary {
        let passed = results.filter(\.passed).count
        let avgFileRecall = results.isEmpty ? 0 : results.map(\.fileRecall).reduce(0, +) / Double(results.count)
        let avgZoneRecall = results.isEmpty ? 0 : results.map(\.zoneRecall).reduce(0, +) / Double(results.count)
        let avgPrecision = results.isEmpty ? 0 : results.map(\.filePrecision).reduce(0, +) / Double(results.count)

        return EvalSummary(
            results: results,
            totalCases: results.count,
            passedCases: passed,
            avgFileRecall: avgFileRecall,
            avgZoneRecall: avgZoneRecall,
            avgPrecision: avgPrecision
        )
    }

    /// Format eval results as a human-readable report.
    func formatReport(summary: EvalSummary) -> String {
        var lines: [String] = []
        lines.append("=== PADA+ Evidence Eval Report ===")
        lines.append("Cases: \(summary.totalCases) | Passed: \(summary.passedCases) | Failed: \(summary.totalCases - summary.passedCases)")
        lines.append("Avg file recall: \(String(format: "%.0f%%", summary.avgFileRecall * 100))")
        lines.append("Avg zone recall: \(String(format: "%.0f%%", summary.avgZoneRecall * 100))")
        lines.append("Avg precision:   \(String(format: "%.0f%%", summary.avgPrecision * 100))")
        lines.append("")

        for result in summary.results {
            let status = result.passed ? "PASS" : "FAIL"
            lines.append("[\(status)] \(result.caseName)")
            lines.append("  Query: \(result.query.prefix(80))")
            lines.append("  Type: \(result.classifiedType.rawValue) (\(result.typeCorrect ? "correct" : "WRONG"))")
            lines.append("  Files: \(result.expectedFileHits)/\(result.expectedFileTotal) | Zones: \(result.expectedZoneHits)/\(result.expectedZoneTotal)")
            lines.append("  Recall: \(String(format: "%.0f%%", result.fileRecall * 100)) | Precision: \(String(format: "%.0f%%", result.filePrecision * 100))")
            lines.append("  Evidence: \(result.totalEvidence) items, ~\(result.totalTokens) tokens")
            if result.governingFileCount > 0 {
                lines.append("  Governing: \(result.governingAnchored)/\(result.governingFileCount) anchored, \(result.governingEvidenceCount) evidence segs")
            }
            lines.append("  Planner: specificity=\(String(format: "%.2f", result.specificityScore)) would_run=\(result.plannerWouldRun ? "YES" : "no")")
            if !result.notes.isEmpty {
                lines.append("  Notes: \(result.notes)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
