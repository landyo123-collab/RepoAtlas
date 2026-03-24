import Foundation

struct Segment {
    let index: Int
    let startLine: Int
    let endLine: Int
    let tokenEstimate: Int
    let segmentType: String  // chunk, function, class, struct, import_block, comment_block
    let label: String
    let content: String
}

struct FileSegmenter {
    static let defaultChunkSize = 60
    static let maxChunkSize = 100
    static let overlapLines = 5

    func segment(text: String, language: String, fileName: String) -> [Segment] {
        let lines = text.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return [] }

        switch language.lowercased() {
        case "swift":
            return segmentStructured(lines: lines, patterns: swiftPatterns)
        case "python":
            return segmentStructured(lines: lines, patterns: pythonPatterns)
        case "javascript", "typescript":
            return segmentStructured(lines: lines, patterns: jstsPatterns)
        case "json":
            return segmentJSON(lines: lines)
        case "yaml":
            return segmentYAML(lines: lines)
        case "toml":
            return segmentTOML(lines: lines)
        case "markdown":
            return segmentMarkdown(lines: lines)
        default:
            return segmentFixed(lines: lines, chunkSize: Self.defaultChunkSize)
        }
    }

    // MARK: - Structured segmentation (language-aware)

    private struct BoundaryPattern {
        let regex: NSRegularExpression
        let type: String
    }

    private var swiftPatterns: [BoundaryPattern] {
        [
            bp(#"^(?:public |private |internal |open |fileprivate )?(?:final )?class\s+\w+"#, "class"),
            bp(#"^(?:public |private |internal )?struct\s+\w+"#, "struct"),
            bp(#"^(?:public |private |internal )?enum\s+\w+"#, "enum"),
            bp(#"^(?:public |private |internal )?protocol\s+\w+"#, "protocol"),
            bp(#"^(?:public |private |internal |open |fileprivate )?(?:@\w+\s+)*(?:static |class )?(?:override )?func\s+\w+"#, "function"),
            bp(#"^(?:public |private |internal )?extension\s+\w+"#, "extension"),
            bp(#"^import\s+"#, "import_block"),
        ]
    }

    private var pythonPatterns: [BoundaryPattern] {
        [
            bp(#"^class\s+\w+"#, "class"),
            bp(#"^(?:async\s+)?def\s+\w+"#, "function"),
            bp(#"^(?:from\s+\S+\s+)?import\s+"#, "import_block"),
            bp(#"^@\w+"#, "decorator"),
        ]
    }

    private var jstsPatterns: [BoundaryPattern] {
        [
            bp(#"^(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+\w+"#, "class"),
            bp(#"^(?:export\s+)?(?:async\s+)?function\s+\w+"#, "function"),
            bp(#"^(?:export\s+)?(?:const|let|var)\s+\w+\s*=\s*(?:async\s+)?\("#, "function"),
            bp(#"^(?:export\s+)?(?:const|let|var)\s+\w+\s*=\s*(?:async\s+)?\(\s*\)\s*=>"#, "function"),
            bp(#"^(?:export\s+)?interface\s+\w+"#, "interface"),
            bp(#"^(?:export\s+)?type\s+\w+"#, "type"),
            bp(#"^import\s+"#, "import_block"),
        ]
    }

    private func bp(_ pattern: String, _ type: String) -> BoundaryPattern {
        BoundaryPattern(
            regex: try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
            type: type
        )
    }

    private func segmentStructured(lines: [String], patterns: [BoundaryPattern]) -> [Segment] {
        guard lines.count > 10 else {
            return [makeSegment(lines: lines, startLine: 1, index: 0, type: "chunk", label: "full file")]
        }

        // Find boundary lines
        var boundaries: [(line: Int, type: String, label: String)] = []

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            for pattern in patterns {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if pattern.regex.firstMatch(in: trimmed, range: range) != nil {
                    // Extract a label from the line
                    let label = extractLabel(from: trimmed, type: pattern.type)
                    boundaries.append((i, pattern.type, label))
                    break
                }
            }
        }

        // If too few boundaries, fall back to fixed chunking
        if boundaries.count < 2 {
            return segmentFixed(lines: lines, chunkSize: Self.defaultChunkSize)
        }

        var segments: [Segment] = []
        var segIndex = 0

        // Group consecutive imports into one block
        var i = 0
        while i < boundaries.count {
            let start = boundaries[i].line
            let type = boundaries[i].type
            let label = boundaries[i].label

            // Find the end: either next boundary or a reasonable end
            let end: Int
            if i + 1 < boundaries.count {
                end = boundaries[i + 1].line
            } else {
                end = lines.count
            }

            // Don't create segments larger than maxChunkSize
            if end - start > Self.maxChunkSize {
                // Split into sub-chunks
                var pos = start
                while pos < end {
                    let chunkEnd = min(pos + Self.defaultChunkSize, end)
                    let chunkLines = Array(lines[pos..<chunkEnd])
                    let seg = makeSegment(lines: chunkLines, startLine: pos + 1, index: segIndex,
                                          type: pos == start ? type : "chunk",
                                          label: pos == start ? label : "\(label) (continued)")
                    segments.append(seg)
                    segIndex += 1
                    pos = chunkEnd
                }
            } else {
                let segLines = Array(lines[start..<end])
                let seg = makeSegment(lines: segLines, startLine: start + 1, index: segIndex,
                                      type: type, label: label)
                segments.append(seg)
                segIndex += 1
            }

            i += 1
        }

        // Handle any leading content before first boundary
        if let firstBoundary = boundaries.first, firstBoundary.line > 0 {
            let preambleLines = Array(lines[0..<firstBoundary.line])
            if !preambleLines.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                let preamble = makeSegment(lines: preambleLines, startLine: 1, index: -1,
                                           type: "preamble", label: "file header")
                segments.insert(preamble, at: 0)
                // Reindex
                for j in 0..<segments.count {
                    segments[j] = Segment(index: j, startLine: segments[j].startLine,
                                          endLine: segments[j].endLine,
                                          tokenEstimate: segments[j].tokenEstimate,
                                          segmentType: segments[j].segmentType,
                                          label: segments[j].label,
                                          content: segments[j].content)
                }
            }
        }

        return segments
    }

    private func extractLabel(from line: String, type: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Try to extract the name
        let namePatterns: [(String, NSRegularExpression)] = [
            ("function", try! NSRegularExpression(pattern: #"(?:func|function|def)\s+(\w+)"#)),
            ("class", try! NSRegularExpression(pattern: #"class\s+(\w+)"#)),
            ("struct", try! NSRegularExpression(pattern: #"struct\s+(\w+)"#)),
            ("enum", try! NSRegularExpression(pattern: #"enum\s+(\w+)"#)),
            ("protocol", try! NSRegularExpression(pattern: #"protocol\s+(\w+)"#)),
            ("interface", try! NSRegularExpression(pattern: #"interface\s+(\w+)"#)),
            ("type", try! NSRegularExpression(pattern: #"type\s+(\w+)"#)),
            ("extension", try! NSRegularExpression(pattern: #"extension\s+(\w+)"#)),
        ]

        for (_, regex) in namePatterns {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
               let captureRange = Range(match.range(at: 1), in: trimmed) {
                return "\(type): \(trimmed[captureRange])"
            }
        }

        if type == "import_block" { return "imports" }
        if type == "decorator" { return "decorator" }

        // Fallback: first 50 chars
        return String(trimmed.prefix(50))
    }

    // MARK: - Markdown segmentation

    private func segmentMarkdown(lines: [String]) -> [Segment] {
        guard lines.count > 10 else {
            return [makeSegment(lines: lines, startLine: 1, index: 0, type: "chunk", label: "full file")]
        }

        var segments: [Segment] = []
        var currentStart = 0
        var currentLabel = "header"
        var segIndex = 0

        for (i, line) in lines.enumerated() {
            if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") {
                // Emit previous segment
                if i > currentStart {
                    let segLines = Array(lines[currentStart..<i])
                    if !segLines.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        segments.append(makeSegment(lines: segLines, startLine: currentStart + 1,
                                                    index: segIndex, type: "section", label: currentLabel))
                        segIndex += 1
                    }
                }
                currentStart = i
                currentLabel = line.trimmingCharacters(in: .init(charactersIn: "# ")).trimmingCharacters(in: .whitespaces)
            }
        }

        // Last segment
        if currentStart < lines.count {
            let segLines = Array(lines[currentStart..<lines.count])
            segments.append(makeSegment(lines: segLines, startLine: currentStart + 1,
                                        index: segIndex, type: "section", label: currentLabel))
        }

        // Split any oversized segments
        return splitOversized(segments)
    }

    // MARK: - JSON segmentation (top-level keys)

    private func segmentJSON(lines: [String]) -> [Segment] {
        guard lines.count > 15 else {
            return [makeSegment(lines: lines, startLine: 1, index: 0, type: "chunk", label: "full file")]
        }

        // Find top-level keys by detecting lines like "  "key": " at indent 2
        var boundaries: [(line: Int, label: String)] = []
        let keyRx = try! NSRegularExpression(pattern: #"^\s{2}"(\w[\w\-]*)"\s*:"#)

        for (i, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if let match = keyRx.firstMatch(in: line, range: range), match.numberOfRanges > 1,
               let nameRange = Range(match.range(at: 1), in: line) {
                boundaries.append((i, String(line[nameRange])))
            }
        }

        guard boundaries.count >= 2 else {
            return segmentFixed(lines: lines, chunkSize: 80)
        }

        var segments: [Segment] = []
        var segIndex = 0
        for (bi, boundary) in boundaries.enumerated() {
            let start = boundary.line
            let end = bi + 1 < boundaries.count ? boundaries[bi + 1].line : lines.count
            let segLines = Array(lines[start..<end])
            if end - start > Self.maxChunkSize {
                var pos = 0
                while pos < segLines.count {
                    let chunkEnd = min(pos + Self.defaultChunkSize, segLines.count)
                    let chunk = Array(segLines[pos..<chunkEnd])
                    segments.append(makeSegment(lines: chunk, startLine: start + pos + 1, index: segIndex,
                                                type: "section", label: pos == 0 ? boundary.label : "\(boundary.label) (cont.)"))
                    segIndex += 1
                    pos = chunkEnd
                }
            } else {
                segments.append(makeSegment(lines: segLines, startLine: start + 1, index: segIndex,
                                            type: "section", label: boundary.label))
                segIndex += 1
            }
        }

        // Preamble before first key
        if let first = boundaries.first, first.line > 0 {
            let pre = Array(lines[0..<first.line])
            if !pre.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                segments.insert(makeSegment(lines: pre, startLine: 1, index: -1, type: "preamble", label: "json header"), at: 0)
                for j in 0..<segments.count {
                    segments[j] = Segment(index: j, startLine: segments[j].startLine, endLine: segments[j].endLine,
                                          tokenEstimate: segments[j].tokenEstimate, segmentType: segments[j].segmentType,
                                          label: segments[j].label, content: segments[j].content)
                }
            }
        }

        return segments
    }

    // MARK: - YAML segmentation (top-level keys)

    private func segmentYAML(lines: [String]) -> [Segment] {
        guard lines.count > 15 else {
            return [makeSegment(lines: lines, startLine: 1, index: 0, type: "chunk", label: "full file")]
        }

        // Top-level keys: non-whitespace start, end with colon
        var boundaries: [(line: Int, label: String)] = []
        let keyRx = try! NSRegularExpression(pattern: #"^([a-zA-Z_][\w\-]*)\s*:"#)

        for (i, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if let match = keyRx.firstMatch(in: line, range: range), match.numberOfRanges > 1,
               let nameRange = Range(match.range(at: 1), in: line) {
                boundaries.append((i, String(line[nameRange])))
            }
        }

        guard boundaries.count >= 2 else {
            return segmentFixed(lines: lines, chunkSize: 60)
        }

        var segments: [Segment] = []
        var segIndex = 0
        for (bi, boundary) in boundaries.enumerated() {
            let start = boundary.line
            let end = bi + 1 < boundaries.count ? boundaries[bi + 1].line : lines.count
            let segLines = Array(lines[start..<end])
            segments.append(makeSegment(lines: segLines, startLine: start + 1, index: segIndex,
                                        type: "section", label: boundary.label))
            segIndex += 1
        }
        return splitOversized(segments)
    }

    // MARK: - TOML segmentation (sections/tables)

    private func segmentTOML(lines: [String]) -> [Segment] {
        guard lines.count > 15 else {
            return [makeSegment(lines: lines, startLine: 1, index: 0, type: "chunk", label: "full file")]
        }

        // TOML sections: [section] or [[array]]
        var boundaries: [(line: Int, label: String)] = []
        let sectionRx = try! NSRegularExpression(pattern: #"^\[+([^\]]+)\]+"#)

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = sectionRx.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
               let nameRange = Range(match.range(at: 1), in: trimmed) {
                boundaries.append((i, String(trimmed[nameRange])))
            }
        }

        guard boundaries.count >= 2 else {
            return segmentFixed(lines: lines, chunkSize: 60)
        }

        var segments: [Segment] = []
        var segIndex = 0

        // Content before first section
        if boundaries[0].line > 0 {
            let pre = Array(lines[0..<boundaries[0].line])
            if !pre.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                segments.append(makeSegment(lines: pre, startLine: 1, index: segIndex, type: "section", label: "top-level"))
                segIndex += 1
            }
        }

        for (bi, boundary) in boundaries.enumerated() {
            let start = boundary.line
            let end = bi + 1 < boundaries.count ? boundaries[bi + 1].line : lines.count
            let segLines = Array(lines[start..<end])
            segments.append(makeSegment(lines: segLines, startLine: start + 1, index: segIndex,
                                        type: "section", label: boundary.label))
            segIndex += 1
        }
        return splitOversized(segments)
    }

    // MARK: - Fixed-size chunking

    private func segmentFixed(lines: [String], chunkSize: Int) -> [Segment] {
        guard lines.count > chunkSize else {
            return [makeSegment(lines: lines, startLine: 1, index: 0, type: "chunk", label: "full file")]
        }

        var segments: [Segment] = []
        var pos = 0
        var segIndex = 0
        while pos < lines.count {
            let end = min(pos + chunkSize, lines.count)
            let chunk = Array(lines[pos..<end])
            segments.append(makeSegment(lines: chunk, startLine: pos + 1, index: segIndex,
                                        type: "chunk", label: "lines \(pos+1)-\(end)"))
            segIndex += 1
            pos = end
        }
        return segments
    }

    // MARK: - Helpers

    private func makeSegment(lines: [String], startLine: Int, index: Int, type: String, label: String) -> Segment {
        let content = lines.joined(separator: "\n")
        return Segment(
            index: index,
            startLine: startLine,
            endLine: startLine + lines.count - 1,
            tokenEstimate: max(1, content.count / 4),
            segmentType: type,
            label: label,
            content: content
        )
    }

    private func splitOversized(_ segments: [Segment]) -> [Segment] {
        var result: [Segment] = []
        var idx = 0
        for seg in segments {
            if seg.tokenEstimate > Self.maxChunkSize * 4 {
                let lines = seg.content.components(separatedBy: .newlines)
                var pos = 0
                while pos < lines.count {
                    let end = min(pos + Self.defaultChunkSize, lines.count)
                    let chunk = Array(lines[pos..<end])
                    result.append(makeSegment(lines: chunk, startLine: seg.startLine + pos,
                                              index: idx, type: seg.segmentType,
                                              label: pos == 0 ? seg.label : "\(seg.label) (cont.)"))
                    idx += 1
                    pos = end
                }
            } else {
                result.append(Segment(index: idx, startLine: seg.startLine, endLine: seg.endLine,
                                      tokenEstimate: seg.tokenEstimate, segmentType: seg.segmentType,
                                      label: seg.label, content: seg.content))
                idx += 1
            }
        }
        return result
    }
}
