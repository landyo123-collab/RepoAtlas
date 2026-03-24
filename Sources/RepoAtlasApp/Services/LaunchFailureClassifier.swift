import Foundation

enum LaunchFailureKind: String {
    case missingInterpreter
    case missingDependency
    case versionIncompatibility
    case repoImportMismatch
    case runtimeFailure
}

struct LaunchFailureClassification {
    let kind: LaunchFailureKind
    let message: String
    let missingModule: String?
}

struct LaunchFailureClassifier {
    func classifyPythonFailure(logs: [String], runError: String?, exitCode: Int32?, repoRoot: URL?) -> LaunchFailureClassification? {
        let errorText = runError ?? ""
        if errorText.localizedCaseInsensitiveContains("No suitable Python interpreter found") ||
            errorText.localizedCaseInsensitiveContains("No such file or directory") {
            return LaunchFailureClassification(
                kind: .missingInterpreter,
                message: "Python interpreter is missing for this run.",
                missingModule: nil
            )
        }
        if (errorText.localizedCaseInsensitiveContains("requires Python") ||
            errorText.localizedCaseInsensitiveContains("require Python")) &&
            errorText.localizedCaseInsensitiveContains("no compatible interpreter") {
            return LaunchFailureClassification(
                kind: .versionIncompatibility,
                message: "Python version incompatibility detected. This repo likely requires a newer interpreter.",
                missingModule: nil
            )
        }

        let recent = logs.suffix(180).joined(separator: "\n")
        if recent.contains("unsupported operand type(s) for |: 'type' and 'NoneType'") ||
            recent.contains("TypeError: unsupported operand type(s) for |") {
            return LaunchFailureClassification(
                kind: .versionIncompatibility,
                message: "Python version incompatibility detected. This repo likely requires Python 3.10+.",
                missingModule: nil
            )
        }
        if let module = firstCapture(
            pattern: #"ModuleNotFoundError:\s*No module named ['"]([^'"]+)['"]"#,
            in: recent
        ) {
            if isLikelyLocalModule(module, repoRoot: repoRoot) {
                return LaunchFailureClassification(
                    kind: .repoImportMismatch,
                    message: "The selected script started, but failed due to a repo import/code mismatch.",
                    missingModule: module
                )
            }
            return LaunchFailureClassification(
                kind: .missingDependency,
                message: "Missing Python dependency/module: \(module). Environment setup may be required.",
                missingModule: module
            )
        }

        if let symbol = firstCapture(
            pattern: #"ImportError:\s*cannot import name ['"]([^'"]+)['"] from ['"]([^'"]+)['"]"#,
            in: recent
        ) {
            let module = secondCapture(
                pattern: #"ImportError:\s*cannot import name ['"]([^'"]+)['"] from ['"]([^'"]+)['"]"#,
                in: recent
            )
            if let module, isLikelyLocalModule(module, repoRoot: repoRoot) {
                return LaunchFailureClassification(
                    kind: .repoImportMismatch,
                    message: "The selected script started, but failed due to a repo import/code mismatch. Missing symbol '\(symbol)' in '\(module)'.",
                    missingModule: module
                )
            }
            return LaunchFailureClassification(
                kind: .runtimeFailure,
                message: "Python import failed while loading symbol '\(symbol)'.",
                missingModule: module
            )
        }

        if recent.contains("ImportError:") || recent.contains("No module named") {
            return LaunchFailureClassification(
                kind: .repoImportMismatch,
                message: "The selected script started, but failed due to a repo import/code mismatch.",
                missingModule: nil
            )
        }

        if let code = exitCode, code != 0 {
            return LaunchFailureClassification(
                kind: .runtimeFailure,
                message: "Python run failed with exit code \(code).",
                missingModule: nil
            )
        }
        return nil
    }

    private func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    private func secondCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges > 2,
              let captureRange = Range(match.range(at: 2), in: text) else { return nil }
        return String(text[captureRange])
    }

    private func isLikelyLocalModule(_ module: String, repoRoot: URL?) -> Bool {
        guard let repoRoot else { return false }
        let normalized = module.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let components = normalized.split(separator: ".").map(String.init)
        guard !components.isEmpty else { return false }
        let relativePath = components.joined(separator: "/")

        let bases = [
            repoRoot,
            repoRoot.appendingPathComponent("src")
        ]
        for base in bases {
            let pyFile = base.appendingPathComponent(relativePath + ".py").path
            let packageDir = base.appendingPathComponent(relativePath).path
            let initFile = base.appendingPathComponent(relativePath).appendingPathComponent("__init__.py").path
            if FileManager.default.fileExists(atPath: pyFile) ||
                FileManager.default.fileExists(atPath: packageDir) ||
                FileManager.default.fileExists(atPath: initFile) {
                return true
            }
        }
        return false
    }
}
