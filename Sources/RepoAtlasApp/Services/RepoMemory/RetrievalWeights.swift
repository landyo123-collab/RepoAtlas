import Foundation

/// Centralized retrieval signal fusion weights.
/// All scoring constants live here so they are inspectable, tunable, and auditable in one place.
struct RetrievalWeights {

    // MARK: - Seed phase weights (how much each signal contributes to initial candidate score)

    /// FTS path/name match base score
    var pathNameMatch: Double = 8.0
    /// FTS segment content match base score
    var contentMatch: Double = 6.0
    /// FTS symbol match base score (highest — symbol hits are strong signal)
    var symbolMatch: Double = 9.0
    /// Manifest file relevance
    var manifest: Double = 3.0
    /// Non-manifest config file relevance
    var config: Double = 1.5
    /// Entrypoint file relevance
    var entrypoint: Double = 2.5
    /// Session recent-file boost
    var sessionRecent: Double = 2.0
    /// Active topic match boost
    var activeTopic: Double = 1.5
    /// Fallback importance+keyword score multiplier
    var fallbackKeyword: Double = 1.5

    // MARK: - Graph expansion weights

    /// Direct neighbor (hop-0) score
    var graphHop0: Double = 3.0
    /// Indirect neighbor (hop-1+) score
    var graphHop1: Double = 1.5

    // MARK: - Tier adjustments (applied in ranking phase)

    var tierFirstParty: Double = 0.0
    var tierProjectSupport: Double = -1.0
    var tierExternalDependency: Double = -8.0
    var tierGeneratedArtifact: Double = -5.0
    var tierBinaryOrIgnored: Double = -15.0

    /// Importance score divisor for bonus
    var importanceDivisor: Double = 5.0

    // MARK: - Tier seed multipliers

    var seedMultFirstParty: Double = 1.0
    var seedMultProjectSupport: Double = 0.7
    var seedMultExternalDependency: Double = 0.1
    var seedMultGeneratedArtifact: Double = 0.2
    var seedMultDefault: Double = 0.05

    // MARK: - Embedding rerank weights

    /// Maximum score boost from file-summary embedding similarity (0-1 range scaled)
    var fileSummaryEmbeddingScale: Double = 6.0
    /// Maximum score boost from chunk-level embedding similarity
    var chunkEmbeddingScale: Double = 4.0
    /// How many top candidates to apply file-summary embedding rerank to
    var fileSummaryRerankSize: Int = 75
    /// How many top segment candidates to consider for chunk-level embedding rerank
    var chunkRerankBudget: Int = 60
    /// Maximum number of chunks to embed lazily per query (API cost bound)
    var lazyEmbedBatchLimit: Int = 48

    // MARK: - Diversity constraints

    var maxSegmentsPerFile: Int = 8
    var maxTokenFractionPerFile: Double = 0.25
    var maxTokenFractionPerProject: Double = 0.50

    // MARK: - Helpers

    func tierAdjustment(for tier: String) -> Double {
        switch tier {
        case "firstParty": return tierFirstParty
        case "projectSupport": return tierProjectSupport
        case "externalDependency": return tierExternalDependency
        case "generatedArtifact": return tierGeneratedArtifact
        case "binaryOrIgnored": return tierBinaryOrIgnored
        default: return tierBinaryOrIgnored
        }
    }

    func seedMultiplier(for tier: String, queryTargetsDeps: Bool) -> Double {
        if queryTargetsDeps { return 1.0 }
        switch tier {
        case "firstParty": return seedMultFirstParty
        case "projectSupport": return seedMultProjectSupport
        case "externalDependency": return seedMultExternalDependency
        case "generatedArtifact": return seedMultGeneratedArtifact
        default: return seedMultDefault
        }
    }

    /// Summary of current weights for debug output
    var debugDescription: String {
        """
        Weights: path=\(pathNameMatch) content=\(contentMatch) symbol=\(symbolMatch) \
        manifest=\(manifest) entrypoint=\(entrypoint) session=\(sessionRecent) \
        topic=\(activeTopic) | embFile=\(fileSummaryEmbeddingScale) embChunk=\(chunkEmbeddingScale) \
        | graph0=\(graphHop0) graph1=\(graphHop1) | divSegPerFile=\(maxSegmentsPerFile) \
        tokPerFile=\(maxTokenFractionPerFile) tokPerProj=\(maxTokenFractionPerProject)
        """
    }

    /// Default production weights
    static let `default` = RetrievalWeights()
}
