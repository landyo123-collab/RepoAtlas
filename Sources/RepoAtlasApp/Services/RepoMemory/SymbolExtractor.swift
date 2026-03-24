import Foundation

struct ExtractedSymbol {
    let name: String
    let kind: String      // function, class, struct, enum, protocol, variable, constant, type, module, interface
    let lineNumber: Int
    let signature: String
    let container: String
}

struct ExtractedReference {
    let targetSymbol: String
    let kind: String       // import, type_ref
    let lineNumber: Int
    let resolvedPath: String  // best-effort resolved relative path, empty if unknown
}

struct SymbolExtractor {

    func extractSymbols(from text: String, language: String) -> [ExtractedSymbol] {
        let lines = text.components(separatedBy: .newlines)
        switch language.lowercased() {
        case "swift": return extractSwiftSymbols(lines: lines)
        case "python": return extractPythonSymbols(lines: lines)
        case "javascript", "typescript": return extractJSTSSymbols(lines: lines)
        default: return []
        }
    }

    func extractReferences(from text: String, language: String, allFilePaths: [String]) -> [ExtractedReference] {
        let lines = text.components(separatedBy: .newlines)
        switch language.lowercased() {
        case "swift": return extractSwiftRefs(lines: lines, allPaths: allFilePaths)
        case "python": return extractPythonRefs(lines: lines, allPaths: allFilePaths)
        case "javascript", "typescript": return extractJSTSRefs(lines: lines, allPaths: allFilePaths)
        default: return []
        }
    }

    // MARK: - Swift

    private func extractSwiftSymbols(lines: [String]) -> [ExtractedSymbol] {
        var symbols: [ExtractedSymbol] = []
        var currentContainer = ""

        let patterns: [(NSRegularExpression, String)] = [
            (rx(#"(?:public |private |internal |open |fileprivate )?(?:final )?class\s+(\w+)"#), "class"),
            (rx(#"(?:public |private |internal )?struct\s+(\w+)"#), "struct"),
            (rx(#"(?:public |private |internal )?enum\s+(\w+)"#), "enum"),
            (rx(#"(?:public |private |internal )?protocol\s+(\w+)"#), "protocol"),
            (rx(#"(?:public |private |internal |open |fileprivate )?(?:static |class )?(?:override )?func\s+(\w+)\s*(\([^)]*\))"#), "function"),
            (rx(#"(?:public |private |internal |open |fileprivate )?(?:static |class )?(?:let|var)\s+(\w+)\s*[=:]"#), "variable"),
            (rx(#"(?:public |private |internal )?typealias\s+(\w+)"#), "type"),
            (rx(#"(?:public |private |internal )?extension\s+(\w+)"#), "extension"),
        ]

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("/*") else { continue }

            for (regex, kind) in patterns {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if let match = regex.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
                   let nameRange = Range(match.range(at: 1), in: trimmed) {
                    let name = String(trimmed[nameRange])

                    var sig = ""
                    if kind == "function" && match.numberOfRanges > 2,
                       let sigRange = Range(match.range(at: 2), in: trimmed) {
                        sig = "func \(name)\(trimmed[sigRange])"
                    }

                    if kind == "class" || kind == "struct" || kind == "enum" || kind == "protocol" || kind == "extension" {
                        currentContainer = name
                    }

                    let container = (kind == "function" || kind == "variable") ? currentContainer : ""
                    symbols.append(ExtractedSymbol(name: name, kind: kind, lineNumber: lineIdx + 1, signature: sig, container: container))
                    break
                }
            }
        }
        return symbols
    }

    private func extractSwiftRefs(lines: [String], allPaths: [String]) -> [ExtractedReference] {
        var refs: [ExtractedReference] = []
        let importRx = rx(#"^\s*import\s+(\w+)"#)

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = importRx.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
               let nameRange = Range(match.range(at: 1), in: trimmed) {
                let module = String(trimmed[nameRange])
                refs.append(ExtractedReference(targetSymbol: module, kind: "import", lineNumber: lineIdx + 1, resolvedPath: ""))
            }
        }
        return refs
    }

    // MARK: - Python

    private func extractPythonSymbols(lines: [String]) -> [ExtractedSymbol] {
        var symbols: [ExtractedSymbol] = []
        var currentClass = ""

        let classRx = rx(#"^class\s+(\w+)"#)
        let funcRx = rx(#"^(?:async\s+)?def\s+(\w+)\s*(\([^)]*\))"#)
        let varRx = rx(#"^(\w+)\s*(?::\s*\w+)?\s*="#)
        let indentedFuncRx = rx(#"^\s+(?:async\s+)?def\s+(\w+)\s*(\([^)]*\))"#)

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let range = NSRange(trimmed.startIndex..., in: trimmed)
            let fullRange = NSRange(line.startIndex..., in: line)

            if let match = classRx.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
               let nameRange = Range(match.range(at: 1), in: trimmed) {
                let name = String(trimmed[nameRange])
                currentClass = name
                symbols.append(ExtractedSymbol(name: name, kind: "class", lineNumber: lineIdx + 1, signature: "", container: ""))
            } else if let match = funcRx.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: trimmed) {
                let name = String(trimmed[nameRange])
                var sig = "def \(name)"
                if match.numberOfRanges > 2, let sigRange = Range(match.range(at: 2), in: trimmed) {
                    sig += String(trimmed[sigRange])
                }
                symbols.append(ExtractedSymbol(name: name, kind: "function", lineNumber: lineIdx + 1, signature: sig, container: ""))
            } else if let match = indentedFuncRx.firstMatch(in: line, range: fullRange), match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: line) {
                let name = String(line[nameRange])
                var sig = "def \(name)"
                if match.numberOfRanges > 2, let sigRange = Range(match.range(at: 2), in: line) {
                    sig += String(line[sigRange])
                }
                symbols.append(ExtractedSymbol(name: name, kind: "function", lineNumber: lineIdx + 1, signature: sig, container: currentClass))
            } else if line.first?.isWhitespace == false {
                if let match = varRx.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
                   let nameRange = Range(match.range(at: 1), in: trimmed) {
                    let name = String(trimmed[nameRange])
                    if name.uppercased() == name && name.count > 1 {
                        symbols.append(ExtractedSymbol(name: name, kind: "constant", lineNumber: lineIdx + 1, signature: "", container: ""))
                    }
                }
                currentClass = ""
            }
        }
        return symbols
    }

    private func extractPythonRefs(lines: [String], allPaths: [String]) -> [ExtractedReference] {
        var refs: [ExtractedReference] = []
        let importRx = rx(#"^\s*import\s+(\S+)"#)
        let fromRx = rx(#"^\s*from\s+(\S+)\s+import"#)

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)

            if let match = importRx.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
               let nameRange = Range(match.range(at: 1), in: trimmed) {
                let module = String(trimmed[nameRange])
                let resolved = resolvePythonModule(module, allPaths: allPaths)
                refs.append(ExtractedReference(targetSymbol: module, kind: "import", lineNumber: lineIdx + 1, resolvedPath: resolved))
            } else if let match = fromRx.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: trimmed) {
                let module = String(trimmed[nameRange])
                let resolved = resolvePythonModule(module, allPaths: allPaths)
                refs.append(ExtractedReference(targetSymbol: module, kind: "import", lineNumber: lineIdx + 1, resolvedPath: resolved))
            }
        }
        return refs
    }

    private func resolvePythonModule(_ module: String, allPaths: [String]) -> String {
        // Convert module.name to module/name.py or module/name/__init__.py
        let parts = module.replacingOccurrences(of: ".", with: "/")
        let candidates = [parts + ".py", parts + "/__init__.py"]
        for candidate in candidates {
            if allPaths.contains(where: { $0.hasSuffix(candidate) }) {
                return allPaths.first { $0.hasSuffix(candidate) } ?? ""
            }
        }
        return ""
    }

    // MARK: - JavaScript / TypeScript

    private func extractJSTSSymbols(lines: [String]) -> [ExtractedSymbol] {
        var symbols: [ExtractedSymbol] = []

        let classRx = rx(#"(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+(\w+)"#)
        let funcRx = rx(#"(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*(\([^)]*\))"#)
        let arrowRx = rx(#"(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?(?:\([^)]*\)|[^=])\s*=>"#)
        let constFuncRx = rx(#"(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?function"#)
        let interfaceRx = rx(#"(?:export\s+)?interface\s+(\w+)"#)
        let typeRx = rx(#"(?:export\s+)?type\s+(\w+)\s*="#)

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("/*") else { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)

            if let match = classRx.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
               let nameRange = Range(match.range(at: 1), in: trimmed) {
                symbols.append(ExtractedSymbol(name: String(trimmed[nameRange]), kind: "class", lineNumber: lineIdx + 1, signature: "", container: ""))
            } else if let match = funcRx.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: trimmed) {
                let name = String(trimmed[nameRange])
                var sig = "function \(name)"
                if match.numberOfRanges > 2, let sigRange = Range(match.range(at: 2), in: trimmed) {
                    sig += String(trimmed[sigRange])
                }
                symbols.append(ExtractedSymbol(name: name, kind: "function", lineNumber: lineIdx + 1, signature: sig, container: ""))
            } else if let match = constFuncRx.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: trimmed) {
                symbols.append(ExtractedSymbol(name: String(trimmed[nameRange]), kind: "function", lineNumber: lineIdx + 1, signature: "", container: ""))
            } else if let match = arrowRx.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: trimmed) {
                symbols.append(ExtractedSymbol(name: String(trimmed[nameRange]), kind: "function", lineNumber: lineIdx + 1, signature: "", container: ""))
            } else if let match = interfaceRx.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: trimmed) {
                symbols.append(ExtractedSymbol(name: String(trimmed[nameRange]), kind: "interface", lineNumber: lineIdx + 1, signature: "", container: ""))
            } else if let match = typeRx.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: trimmed) {
                symbols.append(ExtractedSymbol(name: String(trimmed[nameRange]), kind: "type", lineNumber: lineIdx + 1, signature: "", container: ""))
            }
        }
        return symbols
    }

    private func extractJSTSRefs(lines: [String], allPaths: [String]) -> [ExtractedReference] {
        var refs: [ExtractedReference] = []
        let importRx = rx(#"(?:import|from)\s+[^;]*?['"]([^'"]+)['"]"#)
        let requireRx = rx(#"require\s*\(\s*['"]([^'"]+)['"]\s*\)"#)

        for (lineIdx, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)

            let regexes = [importRx, requireRx]
            for regex in regexes {
                let matches = regex.matches(in: line, range: range)
                for match in matches {
                    guard match.numberOfRanges > 1, let pathRange = Range(match.range(at: 1), in: line) else { continue }
                    let target = String(line[pathRange])
                    let resolved = resolveJSImport(target, allPaths: allPaths)
                    refs.append(ExtractedReference(targetSymbol: target, kind: "import", lineNumber: lineIdx + 1, resolvedPath: resolved))
                }
            }
        }
        return refs
    }

    private func resolveJSImport(_ target: String, allPaths: [String]) -> String {
        guard target.hasPrefix(".") else { return "" }  // skip node_modules imports
        let stripped = target.replacingOccurrences(of: "./", with: "")
        let exts = ["", ".ts", ".tsx", ".js", ".jsx", "/index.ts", "/index.tsx", "/index.js", "/index.jsx"]
        for ext in exts {
            let candidate = stripped + ext
            if let match = allPaths.first(where: { $0.hasSuffix(candidate) }) {
                return match
            }
        }
        return ""
    }

    // MARK: - Helper

    private func rx(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }
}
