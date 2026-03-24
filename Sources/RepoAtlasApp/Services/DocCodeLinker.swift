import Foundation

// MARK: - Doc↔Code Linking (PADA+ Priority 3)

/// Deterministic linker that connects documentation files to code files via:
///   1. Symbol mentions — doc text mentioning CamelCase/snake_case identifiers found in code
///   2. Subtree references — doc referencing directory paths that exist in the repo
///   3. Config key mentions — doc referencing config keys or file names
///   4. Heading-to-subtree heuristics — markdown headings that match subtree names
///
/// Returns scored links that the anchor selector can use to promote related evidence.
struct DocCodeLinker {

    struct DocCodeLink {
        let docPath: String
        let codePath: String
        let linkType: LinkType
        let matchedTerm: String
        let confidence: Double
    }

    enum LinkType: String {
        case symbolMention      // doc mentions a code symbol
        case subtreeReference   // doc references a directory path
        case configKeyMention   // doc mentions a config file or key
        case headingMatch       // doc heading matches a subtree name
        case fileReference      // doc mentions a file by name
    }

    // MARK: - Public API

    /// Find all doc↔code links for the given candidate set.
    func findLinks(
        candidates: [String: PADACandidate],
        store: RepoMemoryStore
    ) -> [DocCodeLink] {
        var links: [DocCodeLink] = []

        let docCandidates = candidates.values.filter { $0.fileType == "docs" }
        let codeCandidates = candidates.values.filter { $0.fileType == "source" || $0.fileType == "entrypoint" }
        let configCandidates = candidates.values.filter { $0.fileType == "config" }

        guard !docCandidates.isEmpty else { return [] }

        // Build a symbol name → code path index from code candidates
        var symbolIndex: [String: String] = [:]  // lowercased name → path
        for candidate in codeCandidates {
            let symbols = store.symbols(forFileId: candidate.fileId)
            for sym in symbols {
                symbolIndex[sym.name.lowercased()] = candidate.path
            }
        }

        // Build a subtree name set from all candidate paths
        var subtreeNames = Set<String>()
        for candidate in candidates.values {
            let components = candidate.path.split(separator: "/")
            for component in components.dropLast() {
                subtreeNames.insert(String(component))
            }
        }

        // Build a file name set
        var fileNames: [String: String] = [:]  // filename → path
        for candidate in candidates.values {
            let name = (candidate.path as NSString).lastPathComponent
            fileNames[name.lowercased()] = candidate.path
        }

        // Scan each doc file's segments for links
        for doc in docCandidates {
            let segments = store.segments(forFileId: doc.fileId)

            for seg in segments.prefix(8) {
                let content = seg.content
                let contentLower = content.lowercased()

                // 1. Symbol mentions
                for (symbolLower, codePath) in symbolIndex {
                    guard symbolLower.count >= 4 else { continue }  // skip very short names
                    if contentLower.contains(symbolLower) {
                        links.append(DocCodeLink(
                            docPath: doc.path,
                            codePath: codePath,
                            linkType: .symbolMention,
                            matchedTerm: symbolLower,
                            confidence: 0.8
                        ))
                    }
                }

                // 2. Subtree/directory references
                for subtree in subtreeNames {
                    guard subtree.count >= 3 else { continue }
                    let subtreeLower = subtree.lowercased()
                    // Look for directory-like references: "src/", "/controllers", "Sources/App"
                    if contentLower.contains(subtreeLower + "/") || contentLower.contains("/" + subtreeLower) {
                        // Find the first candidate in this subtree
                        if let matchedPath = candidates.values.first(where: { $0.path.lowercased().contains(subtreeLower + "/") })?.path {
                            links.append(DocCodeLink(
                                docPath: doc.path,
                                codePath: matchedPath,
                                linkType: .subtreeReference,
                                matchedTerm: subtree,
                                confidence: 0.7
                            ))
                        }
                    }
                }

                // 3. File name references (e.g., "see Package.swift", "defined in RepoStore.swift")
                for (fileNameLower, filePath) in fileNames {
                    guard fileNameLower.count >= 4 else { continue }
                    if contentLower.contains(fileNameLower) {
                        links.append(DocCodeLink(
                            docPath: doc.path,
                            codePath: filePath,
                            linkType: .fileReference,
                            matchedTerm: fileNameLower,
                            confidence: 0.85
                        ))
                    }
                }

                // 4. Config key mentions
                for config in configCandidates {
                    let configName = (config.path as NSString).lastPathComponent.lowercased()
                    if contentLower.contains(configName) {
                        links.append(DocCodeLink(
                            docPath: doc.path,
                            codePath: config.path,
                            linkType: .configKeyMention,
                            matchedTerm: configName,
                            confidence: 0.75
                        ))
                    }
                }

                // 5. Heading-to-subtree heuristic (markdown headings matching directory names)
                if seg.segmentType == "section" || seg.segmentType == "chunk" {
                    let headingPattern = try? NSRegularExpression(pattern: "^#{1,4}\\s+(.+)$", options: .anchorsMatchLines)
                    if let matches = headingPattern?.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
                        for match in matches {
                            if let range = Range(match.range(at: 1), in: content) {
                                let heading = String(content[range]).lowercased().trimmingCharacters(in: .whitespaces)
                                // Check if heading matches any subtree
                                for subtree in subtreeNames {
                                    let subtreeLower = subtree.lowercased()
                                    if heading.contains(subtreeLower) || subtreeLower.contains(heading) {
                                        if let matchedPath = candidates.values.first(where: { $0.path.lowercased().contains(subtreeLower + "/") })?.path {
                                            links.append(DocCodeLink(
                                                docPath: doc.path,
                                                codePath: matchedPath,
                                                linkType: .headingMatch,
                                                matchedTerm: heading,
                                                confidence: 0.6
                                            ))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Deduplicate: keep highest confidence per (doc, code) pair
        var bestLinks: [String: DocCodeLink] = [:]
        for link in links {
            let key = "\(link.docPath)|\(link.codePath)"
            if let existing = bestLinks[key] {
                if link.confidence > existing.confidence {
                    bestLinks[key] = link
                }
            } else {
                bestLinks[key] = link
            }
        }

        return Array(bestLinks.values).sorted { $0.confidence > $1.confidence }
    }

    /// Boost candidate scores based on doc↔code links.
    /// If a doc mentions a code file, boost that code file's score.
    /// If a code file is mentioned by a doc in the candidate set, boost both.
    func applyLinkBoosts(candidates: inout [String: PADACandidate], links: [DocCodeLink]) {
        for link in links {
            let boost = link.confidence * 1.5

            // Boost the code file
            if var code = candidates[link.codePath] {
                code.score += boost
                code.provenance.append(EvidenceProvenance(
                    source: .structuralRole,
                    trigger: "doc_link:\(link.linkType.rawValue):\(link.matchedTerm)",
                    hopDistance: 0,
                    score: boost
                ))
                candidates[link.codePath] = code
            }

            // Boost the doc file (smaller boost)
            if var doc = candidates[link.docPath] {
                doc.score += boost * 0.5
                doc.provenance.append(EvidenceProvenance(
                    source: .structuralRole,
                    trigger: "code_link:\(link.linkType.rawValue):\(link.matchedTerm)",
                    hopDistance: 0,
                    score: boost * 0.5
                ))
                candidates[link.docPath] = doc
            }
        }
    }
}
