import Foundation

// MARK: - PADA+ Evidence Dossier

/// Provenance-Aware Dossier Assembler output.
/// Every evidence object tracks its discovery provenance (how it was found),
/// confidence is computed from structural conditions (not LLM-guessed),
/// and coverage gaps are reported honestly from what the graph reveals.
struct EvidenceDossier: Codable {
    let queryIntent: QueryIntent
    let queryPolicy: QueryPolicy
    let repoFrame: RepoFrame
    let implementationPath: ImplementationPath
    let mustReadFiles: [MustReadFile]
    let exactEvidence: [ExactEvidence]
    let supportingContext: [SupportingContext]
    let missingEvidence: [MissingEvidence]
    let coverageReport: CoverageReport
    let droppedCandidates: [DroppedCandidate]
    let confidenceReport: ConfidenceReport
    let builderDiagnostics: BuilderDiagnostics
    let governingFiles: [GoverningFileInfo]
    let plannerMetadata: PlannerMetadata?
    /// Compact manifest of ALL first-party files — gives DeepSeek full repo awareness
    let repoFileManifest: [RepoFileManifest]

    enum CodingKeys: String, CodingKey {
        case queryIntent = "query_intent"
        case queryPolicy = "query_policy"
        case repoFrame = "repo_frame"
        case implementationPath = "implementation_path"
        case mustReadFiles = "must_read_files"
        case exactEvidence = "exact_evidence"
        case supportingContext = "supporting_context"
        case missingEvidence = "missing_evidence"
        case coverageReport = "coverage_report"
        case droppedCandidates = "dropped_candidates"
        case confidenceReport = "confidence_report"
        case builderDiagnostics = "builder_diagnostics"
        case governingFiles = "governing_files"
        case plannerMetadata = "planner_metadata"
        case repoFileManifest = "repo_file_manifest"
    }
}

// MARK: - Repo File Manifest (compact repo-wide awareness)

/// Lightweight summary of a first-party file for the repo manifest.
/// ~20 tokens each — gives DeepSeek awareness of every file in the repo.
struct RepoFileManifest: Codable {
    let path: String
    let fileType: String
    let lineCount: Int
    let summary: String
    /// Whether this file has evidence segments in the dossier
    let hasEvidence: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case fileType = "file_type"
        case lineCount = "line_count"
        case summary
        case hasEvidence = "has_evidence"
    }
}

// MARK: - Governing File Info (dossier-level tracking)

struct GoverningFileInfo: Codable {
    let path: String
    let governingType: String
    let priority: Double
    let reason: String
    /// Whether exact evidence was anchored from this governing file
    let anchored: Bool
    /// Number of segments anchored from this file
    let anchoredSegments: Int

    enum CodingKeys: String, CodingKey {
        case path
        case governingType = "governing_type"
        case priority, reason, anchored
        case anchoredSegments = "anchored_segments"
    }
}

// MARK: - Query Intent (deterministic classification)

struct QueryIntent: Codable {
    let primary: QueryType
    let secondary: [QueryType]
    let confidence: Double
    /// Deterministic keywords extracted from the query
    let extractedTerms: [String]
    /// Symbol-like tokens found in the query (CamelCase, snake_case, dotted paths)
    let symbolHints: [String]

    enum CodingKeys: String, CodingKey {
        case primary, secondary, confidence
        case extractedTerms = "extracted_terms"
        case symbolHints = "symbol_hints"
    }
}

/// Query types that drive retrieval policy decisions.
enum QueryType: String, Codable {
    case implementation    // "how does X work", "where is X implemented"
    case architecture      // "how is this structured", "what are the major zones"
    case debugging         // "why does X fail", "what causes Y error"
    case mixed             // multiple intents detected
    case wholeSystem       // "summarize", "give me a tour", "what does this repo do"
}

// MARK: - Query Policy (deterministic retrieval strategy)

/// Retrieval policy computed deterministically from query type.
/// Controls graph traversal depth, segment budgets, tier preferences.
struct QueryPolicy: Codable {
    let queryType: QueryType
    let graphHops: Int
    let maxFiles: Int
    let maxSegmentsPerFile: Int
    let maxTotalSegments: Int
    let tokenBudget: Int
    let preferredFileTypes: [String]     // e.g. ["source", "entrypoint"] for implementation
    let preferredTiers: [String]         // e.g. ["firstParty"] for most queries
    let includeTests: Bool
    let includeDocs: Bool
    let symbolTraversalDepth: Int        // how many hops along symbol references

    enum CodingKeys: String, CodingKey {
        case queryType = "query_type"
        case graphHops = "graph_hops"
        case maxFiles = "max_files"
        case maxSegmentsPerFile = "max_segments_per_file"
        case maxTotalSegments = "max_total_segments"
        case tokenBudget = "token_budget"
        case preferredFileTypes = "preferred_file_types"
        case preferredTiers = "preferred_tiers"
        case includeTests = "include_tests"
        case includeDocs = "include_docs"
        case symbolTraversalDepth = "symbol_traversal_depth"
    }
}

// MARK: - Evidence Provenance

/// Tracks exactly how a piece of evidence was discovered.
enum EvidenceSource: String, Codable {
    case ftsPath = "fts_path"           // FTS match on file path/name
    case ftsContent = "fts_content"     // FTS match on segment content
    case ftsSymbol = "fts_symbol"       // FTS match on symbol name
    case graphImport = "graph_import"   // import graph traversal
    case graphReference = "graph_ref"   // symbol reference graph
    case graphDirectory = "graph_dir"   // same-directory neighbor
    case structuralRole = "structural"  // entrypoint/manifest/config by role
    case sessionMemory = "session"      // session recent files
    case modelScreening = "model"       // LLM screening pass
    case modelExpansion = "model_expand" // LLM expansion hint
    case seedRetrieval = "seed"         // from initial RepoRetriever
    case governing = "governing"        // governing file anchor (deep truth-source)
    case plannerHint = "planner_hint"   // planner-requested file/dir/symbol boost
}

/// Full provenance chain for a discovered file or evidence item.
struct EvidenceProvenance: Codable {
    let source: EvidenceSource
    /// The search term, symbol name, or file path that led to discovery
    let trigger: String
    /// How many hops from the original query (0 = direct match)
    let hopDistance: Int
    /// Score contribution from this discovery channel
    let score: Double

    enum CodingKeys: String, CodingKey {
        case source, trigger
        case hopDistance = "hop_distance"
        case score
    }
}

// MARK: - Repo Frame

struct RepoFrame: Codable {
    let oneSentenceIdentity: String
    let relevantSubtrees: [RelevantSubtree]

    enum CodingKeys: String, CodingKey {
        case oneSentenceIdentity = "one_sentence_identity"
        case relevantSubtrees = "relevant_subtrees"
    }
}

struct RelevantSubtree: Codable {
    let path: String
    let whyRelevant: String
    let priority: Double

    enum CodingKeys: String, CodingKey {
        case path
        case whyRelevant = "why_relevant"
        case priority
    }
}

// MARK: - Implementation Path

struct ImplementationPath: Codable {
    let summary: String
    let steps: [ImplementationStep]
}

struct ImplementationStep: Codable {
    let order: Int
    let path: String
    let symbol: String
    let role: String             // entrypoint|orchestrator|service|storage|api|ui|test|doc
    let whyItMatters: String
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case order, path, symbol, role
        case whyItMatters = "why_it_matters"
        case confidence
    }
}

// MARK: - Must-Read Files (provenance-rich)

struct MustReadFile: Codable {
    let path: String
    let role: String
    let priority: Double
    let why: String
    /// Full provenance chain — how this file was discovered
    let provenance: [EvidenceProvenance]

    enum CodingKeys: String, CodingKey {
        case path, role, priority, why, provenance
    }
}

// MARK: - Exact Evidence (provenance-rich)

struct ExactEvidence: Codable {
    let path: String
    let lineRange: String
    let symbol: String
    let kind: String             // code|markdown|config|test
    let relevance: Double
    let why: String
    let excerpt: String
    /// How this evidence was discovered
    let provenance: [EvidenceProvenance]

    enum CodingKeys: String, CodingKey {
        case path
        case lineRange = "line_range"
        case symbol, kind, relevance, why, excerpt, provenance
    }
}

// MARK: - Supporting Context

struct SupportingContext: Codable {
    let path: String
    let kind: String             // doc|summary|subtree|test|config
    let why: String
    let excerpt: String
}

// MARK: - Missing Evidence

struct MissingEvidence: Codable {
    let pathOrArea: String
    let reason: String
    let severity: String         // low|medium|high

    enum CodingKeys: String, CodingKey {
        case pathOrArea = "path_or_area"
        case reason, severity
    }
}

// MARK: - Coverage Report (structurally computed)

/// Coverage computed from what the graph actually found vs what the query needs.
/// NOT LLM-guessed — derived from structural conditions.
struct CoverageReport: Codable {
    /// What fraction of query terms had at least one FTS hit
    let queryTermCoverage: Double
    /// What fraction of discovered symbols had their definition found
    let symbolDefinitionCoverage: Double
    /// What fraction of discovered files had their imports also in the evidence set
    let importGraphCoverage: Double
    /// Specific gaps identified structurally
    let gaps: [CoverageGap]
    /// Total first-party files in repo
    let totalFirstPartyFiles: Int
    /// Files examined by the builder
    let filesExamined: Int
    /// Files included in final evidence
    let filesIncluded: Int

    enum CodingKeys: String, CodingKey {
        case queryTermCoverage = "query_term_coverage"
        case symbolDefinitionCoverage = "symbol_definition_coverage"
        case importGraphCoverage = "import_graph_coverage"
        case gaps
        case totalFirstPartyFiles = "total_first_party_files"
        case filesExamined = "files_examined"
        case filesIncluded = "files_included"
    }
}

/// A specific coverage gap found by structural analysis.
struct CoverageGap: Codable {
    let area: String
    let gapType: GapType
    let description: String

    enum CodingKeys: String, CodingKey {
        case area
        case gapType = "gap_type"
        case description
    }
}

enum GapType: String, Codable {
    case noFTSHit = "no_fts_hit"                    // query term had zero FTS matches
    case symbolNotResolved = "symbol_unresolved"      // symbol mentioned but definition not found
    case importNotFollowed = "import_not_followed"    // import edge exists but target not in evidence
    case noTestCoverage = "no_test_coverage"          // no test files found for relevant code
    case noDocCoverage = "no_doc_coverage"            // no docs found for relevant area
    case largeFilePartial = "large_file_partial"      // large file only partially included
    case subtreeUnexplored = "subtree_unexplored"     // relevant subtree has no files in evidence
}

// MARK: - Dropped Candidate

struct DroppedCandidate: Codable {
    let path: String
    let reason: String           // token_budget|low_relevance|duplicate|overshadowed|noise
}

// MARK: - Confidence Report (structurally computed)

struct ConfidenceReport: Codable {
    let overall: Double
    let implementationCoverage: Double
    let docCoverage: Double
    let executionPathConfidence: Double

    enum CodingKeys: String, CodingKey {
        case overall
        case implementationCoverage = "implementation_coverage"
        case docCoverage = "doc_coverage"
        case executionPathConfidence = "execution_path_confidence"
    }
}

// MARK: - Builder Diagnostics (not sent to DeepSeek, but exposed in UI)

struct BuilderDiagnostics: Codable {
    let totalCandidatesConsidered: Int
    let totalSegmentsExamined: Int
    let passesRun: Int
    let totalBuilderTokensUsed: Int
    let dossierTokenEstimate: Int
    let elapsedMs: Int
    let stages: [StageLog]
    let usedModel: String
    let fallbackUsed: Bool
    let queryPolicy: QueryPolicy

    enum CodingKeys: String, CodingKey {
        case totalCandidatesConsidered = "total_candidates_considered"
        case totalSegmentsExamined = "total_segments_examined"
        case passesRun = "passes_run"
        case totalBuilderTokensUsed = "total_builder_tokens_used"
        case dossierTokenEstimate = "dossier_token_estimate"
        case elapsedMs = "elapsed_ms"
        case stages
        case usedModel = "used_model"
        case fallbackUsed = "fallback_used"
        case queryPolicy = "query_policy"
    }
}

struct StageLog: Codable {
    let name: String
    let candidatesIn: Int
    let candidatesOut: Int
    let tokensUsed: Int
    let durationMs: Int
    let notes: String

    enum CodingKeys: String, CodingKey {
        case name
        case candidatesIn = "candidates_in"
        case candidatesOut = "candidates_out"
        case tokensUsed = "tokens_used"
        case durationMs = "duration_ms"
        case notes
    }
}

// MARK: - Intermediate types used during evidence building

/// Internal candidate with provenance tracking.
struct PADACandidate {
    let fileId: Int64
    let path: String
    var score: Double
    var provenance: [EvidenceProvenance]
    let language: String
    let lineCount: Int
    let importance: Double
    let tier: String
    let fileType: String
    let summary: String
    let roleTags: [String]
}

/// Compact file manifest entry — sent to the model for candidate screening.
struct FileManifestEntry: Codable {
    let path: String
    let language: String
    let lineCount: Int
    let importance: Double
    let tier: String
    let fileType: String
    let summary: String
    let roleTags: [String]
    let symbols: [String]

    enum CodingKeys: String, CodingKey {
        case path, language
        case lineCount = "line_count"
        case importance, tier
        case fileType = "file_type"
        case summary
        case roleTags = "role_tags"
        case symbols
    }
}

/// Candidate file with segments, ready for detailed evidence extraction.
struct CandidateFileDetail: Codable {
    let path: String
    let language: String
    let importance: Double
    let summary: String
    let segments: [CandidateSegment]
}

struct CandidateSegment: Codable {
    let startLine: Int
    let endLine: Int
    let segmentType: String
    let label: String
    let content: String
    let tokenEstimate: Int

    enum CodingKeys: String, CodingKey {
        case startLine = "start_line"
        case endLine = "end_line"
        case segmentType = "segment_type"
        case label
        case content
        case tokenEstimate = "token_estimate"
    }
}

// MARK: - Model response types (what OpenAI returns)

/// Response from the candidate screening pass.
struct ScreeningResponse: Codable {
    let selectedPaths: [SelectedPath]
    let suggestedExpansions: [String]
    let clusterSummaries: [ClusterSummary]

    enum CodingKeys: String, CodingKey {
        case selectedPaths = "selected_paths"
        case suggestedExpansions = "suggested_expansions"
        case clusterSummaries = "cluster_summaries"
    }
}

struct SelectedPath: Codable {
    let path: String
    let priority: Double
    let role: String
    let reason: String
}

struct ClusterSummary: Codable {
    let subtree: String
    let summary: String
    let fileCount: Int
    let relevance: Double

    enum CodingKeys: String, CodingKey {
        case subtree, summary
        case fileCount = "file_count"
        case relevance
    }
}

/// Response from the evidence extraction pass.
struct EvidenceExtractionResponse: Codable {
    let implementationPath: ImplementationPath
    let exactEvidence: [ExactEvidence]
    let supportingContext: [SupportingContext]
    let missingEvidence: [MissingEvidence]
    let confidenceReport: ConfidenceReport

    enum CodingKeys: String, CodingKey {
        case implementationPath = "implementation_path"
        case exactEvidence = "exact_evidence"
        case supportingContext = "supporting_context"
        case missingEvidence = "missing_evidence"
        case confidenceReport = "confidence_report"
    }
}
