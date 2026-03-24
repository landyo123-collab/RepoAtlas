import Foundation

// MARK: - Governing File Detection (PADA+ WholeSystem Hardening)

/// Detects "governing files" — docs that define the repo's current reality, structure,
/// status, rules, or live map. For wholeSystem / architecture queries, these files
/// must receive deeper deterministic anchoring than normal docs.
///
/// Governing file signals (deterministic, no LLM):
///   - Root-level location (depth 0-1)
///   - Filename patterns: index, readme, anchor, overview, status, map, blueprint
///   - Structural role tags: docs, manifest
///   - High importance score
///   - Being referenced by other governing docs (transitive governing)
struct GoverningFileDetector {

    /// A file identified as governing the repo's truth/structure.
    struct GoverningFile {
        let path: String
        let fileId: Int64
        let governingType: GoverningType
        let priority: Double
        let reason: String
    }

    enum GoverningType: String, Codable {
        case repoMap          // Index.md, repo map, live state
        case readme           // README at root or major subtree
        case anchor           // ANCHOR.md, rules, laws
        case statusOverview   // status, phase, changelog
        case blueprint        // architecture, design, theory
        case manifest         // Package.swift, project.yml, Cargo.toml
        case subtreeReadme    // README in a subdirectory
    }

    /// Name patterns that indicate governing files, with their governing types.
    private static let governingPatterns: [(pattern: String, type: GoverningType, rootOnly: Bool)] = [
        // Repo maps / indexes
        ("index.md", .repoMap, true),
        ("index.txt", .repoMap, true),
        ("index.rst", .repoMap, true),
        // READMEs
        ("readme.md", .readme, false),
        ("readme.txt", .readme, false),
        ("readme.rst", .readme, false),
        ("readme", .readme, false),
        // Anchors / rules
        ("anchor.md", .anchor, true),
        ("anchor.txt", .anchor, true),
        ("rules.md", .anchor, true),
        ("laws.md", .anchor, true),
        ("principles.md", .anchor, true),
        // Status / phase
        ("status.md", .statusOverview, false),
        ("changelog.md", .statusOverview, false),
        ("changes.md", .statusOverview, false),
        ("phase.md", .statusOverview, false),
        ("progress.md", .statusOverview, false),
        // Architecture / blueprint
        ("architecture.md", .blueprint, false),
        ("design.md", .blueprint, false),
        ("blueprint.md", .blueprint, false),
        ("overview.md", .blueprint, false),
        ("structure.md", .blueprint, false),
        // Manifests
        ("package.swift", .manifest, true),
        ("cargo.toml", .manifest, true),
        ("package.json", .manifest, true),
        ("project.yml", .manifest, true),
        ("podfile", .manifest, true),
        ("gemfile", .manifest, true),
        ("build.gradle", .manifest, true),
        ("pom.xml", .manifest, true),
        ("makefile", .manifest, true),
        ("cmakelists.txt", .manifest, true),
    ]

    // MARK: - Public API

    /// Detect governing files from the candidate set and repo store.
    /// Returns governing files sorted by priority (highest first).
    func detect(
        candidates: [String: PADACandidate],
        store: RepoMemoryStore,
        queryType: QueryType
    ) -> [GoverningFile] {
        var governing: [GoverningFile] = []
        var seen = Set<String>()

        // Pass 1: Pattern-based detection from candidates
        for candidate in candidates.values {
            if let gf = matchGoverningPattern(candidate: candidate) {
                if !seen.contains(gf.path) {
                    governing.append(gf)
                    seen.insert(gf.path)
                }
            }
        }

        // Pass 2: Pattern-based detection from ALL first-party files
        // (governing files might not be in candidates if query terms didn't match)
        if queryType == .wholeSystem || queryType == .architecture {
            let allFirstParty = store.firstPartyFiles(limit: 500)
            for file in allFirstParty {
                guard !seen.contains(file.relativePath) else { continue }
                let candidate = PADACandidate(
                    fileId: file.id, path: file.relativePath, score: file.importanceScore,
                    provenance: [], language: file.language, lineCount: file.lineCount,
                    importance: file.importanceScore, tier: file.corpusTier,
                    fileType: file.fileType, summary: file.summary, roleTags: file.roleTags
                )
                if let gf = matchGoverningPattern(candidate: candidate) {
                    governing.append(gf)
                    seen.insert(gf.path)
                }
            }
        }

        // Pass 3: Subtree READMEs for wholeSystem queries
        if queryType == .wholeSystem {
            let subtrees = store.allSubtreeSummaries()
            for subtree in subtrees.prefix(8) {
                let readmePath = subtree.root.isEmpty ? "README.md" : subtree.root + "/README.md"
                guard !seen.contains(readmePath) else { continue }
                if let file = store.file(byPath: readmePath) {
                    governing.append(GoverningFile(
                        path: file.relativePath,
                        fileId: file.id,
                        governingType: .subtreeReadme,
                        priority: 3.0,
                        reason: "subtree README for \(subtree.root.isEmpty ? "root" : subtree.root)"
                    ))
                    seen.insert(file.relativePath)
                }
            }
        }

        // Sort by priority descending, then by governing type importance
        governing.sort { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return governingTypeRank(a.governingType) < governingTypeRank(b.governingType)
        }

        // Limit based on query type
        let maxGoverning: Int
        switch queryType {
        case .wholeSystem: maxGoverning = 12
        case .architecture: maxGoverning = 8
        default: maxGoverning = 3
        }

        return Array(governing.prefix(maxGoverning))
    }

    // MARK: - Pattern Matching

    private func matchGoverningPattern(candidate: PADACandidate) -> GoverningFile? {
        let fileName = (candidate.path as NSString).lastPathComponent.lowercased()
        let depth = candidate.path.components(separatedBy: "/").count - 1
        let isRoot = depth <= 1

        // Check directory-level patterns (e.g., "Theory&Blueprint/" directory docs)
        let dirName = ((candidate.path as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()
        let isBlueprintDir = dirName.contains("blueprint") || dirName.contains("theory") ||
                             dirName.contains("architecture") || dirName.contains("design")

        for pattern in Self.governingPatterns {
            if fileName == pattern.pattern || fileName.hasPrefix(pattern.pattern.replacingOccurrences(of: ".md", with: "")) && fileName.hasSuffix(".md") {
                if pattern.rootOnly && !isRoot { continue }

                let basePriority: Double
                switch pattern.type {
                case .repoMap: basePriority = 10.0
                case .readme: basePriority = isRoot ? 9.0 : 4.0
                case .anchor: basePriority = 8.0
                case .statusOverview: basePriority = 7.0
                case .blueprint: basePriority = 6.0
                case .manifest: basePriority = 5.0
                case .subtreeReadme: basePriority = 3.0
                }

                let depthBonus = isRoot ? 2.0 : 0.0
                let importanceBonus = candidate.importance * 2.0

                return GoverningFile(
                    path: candidate.path,
                    fileId: candidate.fileId,
                    governingType: pattern.type,
                    priority: basePriority + depthBonus + importanceBonus,
                    reason: "\(pattern.type.rawValue): \(fileName) at depth \(depth)"
                )
            }
        }

        // Check blueprint-directory docs
        if isBlueprintDir && (candidate.fileType == "docs" || fileName.hasSuffix(".md")) {
            return GoverningFile(
                path: candidate.path,
                fileId: candidate.fileId,
                governingType: .blueprint,
                priority: 5.0 + candidate.importance,
                reason: "blueprint-dir doc: \(candidate.path)"
            )
        }

        return nil
    }

    private func governingTypeRank(_ type: GoverningType) -> Int {
        switch type {
        case .repoMap: return 0
        case .readme: return 1
        case .anchor: return 2
        case .statusOverview: return 3
        case .blueprint: return 4
        case .manifest: return 5
        case .subtreeReadme: return 6
        }
    }
}
