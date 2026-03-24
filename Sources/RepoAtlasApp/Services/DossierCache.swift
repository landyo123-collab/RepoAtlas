import Foundation

// MARK: - Dossier Cache (PADA+ Priority 2)

/// Versioned dossier cache keyed by:
///   - repo hash (changes when repo memory is rebuilt)
///   - query text (normalized)
///   - candidate fingerprint (sorted paths of top candidates)
///   - query policy fingerprint
///   - builder version
///
/// Invalidation: any change to repo hash or builder version invalidates all entries.
/// Cache stored as JSON files in the repo's .repoatlas/dossier_cache/ directory.
struct DossierCache {

    /// Builder version. Bump this when the pipeline logic changes meaningfully.
    static let builderVersion = "pada-3.0"

    private let cacheDir: String

    init(repoRoot: String) {
        self.cacheDir = (repoRoot as NSString).appendingPathComponent(".repoatlas/dossier_cache")
    }

    // MARK: - Public API

    /// Look up a cached dossier. Returns nil on miss.
    func lookup(query: String, repoHash: String, candidateFingerprint: String, queryPolicy: QueryPolicy) -> CachedDossier? {
        let key = cacheKey(query: query, repoHash: repoHash, candidateFingerprint: candidateFingerprint, queryPolicy: queryPolicy)
        let path = cachePath(for: key)

        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entry = try? decoder.decode(CachedDossier.self, from: data) else { return nil }

        // Validate version and repo hash
        guard entry.builderVersion == Self.builderVersion,
              entry.repoHash == repoHash else {
            // Stale — remove it
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }

        // Age check: expire after 24 hours
        let age = Date().timeIntervalSince(entry.createdAt)
        if age > 86_400 {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }

        return entry
    }

    /// Store a dossier in the cache.
    func store(dossier: EvidenceDossier, query: String, repoHash: String, candidateFingerprint: String, queryPolicy: QueryPolicy) {
        let key = cacheKey(query: query, repoHash: repoHash, candidateFingerprint: candidateFingerprint, queryPolicy: queryPolicy)
        let path = cachePath(for: key)

        let entry = CachedDossier(
            cacheKey: key,
            repoHash: repoHash,
            builderVersion: Self.builderVersion,
            createdAt: Date(),
            dossier: dossier
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(entry) else { return }

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: data)
    }

    /// Invalidate all cached dossiers for this repo.
    func invalidateAll() {
        try? FileManager.default.removeItem(atPath: cacheDir)
    }

    /// Remove entries older than the given age (in seconds).
    func evictOlderThan(_ maxAge: TimeInterval) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: cacheDir) else { return }
        for entry in entries {
            let path = (cacheDir as NSString).appendingPathComponent(entry)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let modDate = attrs[.modificationDate] as? Date else { continue }
            if Date().timeIntervalSince(modDate) > maxAge {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Fingerprinting

    /// Build a candidate fingerprint from sorted candidate paths.
    static func candidateFingerprint(from candidates: [String: PADACandidate]) -> String {
        let sortedPaths = candidates.keys.sorted()
        let joined = sortedPaths.joined(separator: "|")
        return joined.sha256Hex
    }

    /// Build a policy fingerprint.
    private func policyFingerprint(_ policy: QueryPolicy) -> String {
        let components = [
            policy.queryType.rawValue,
            "\(policy.graphHops)",
            "\(policy.maxFiles)",
            "\(policy.maxSegmentsPerFile)",
            "\(policy.tokenBudget)",
            "\(policy.symbolTraversalDepth)",
            policy.includeTests ? "t" : "f",
            policy.includeDocs ? "d" : "f"
        ]
        return components.joined(separator: "-")
    }

    // MARK: - Key Construction

    private func cacheKey(query: String, repoHash: String, candidateFingerprint: String, queryPolicy: QueryPolicy) -> String {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let policyFP = policyFingerprint(queryPolicy)
        let raw = "\(Self.builderVersion)|\(repoHash)|\(normalized)|\(candidateFingerprint)|\(policyFP)"
        return raw.sha256Hex
    }

    private func cachePath(for key: String) -> String {
        (cacheDir as NSString).appendingPathComponent("\(key).json")
    }
}

// MARK: - Cached Dossier Entry

struct CachedDossier: Codable {
    let cacheKey: String
    let repoHash: String
    let builderVersion: String
    let createdAt: Date
    let dossier: EvidenceDossier
}
