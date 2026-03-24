import Foundation

struct PythonVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    var displayString: String {
        "\(major).\(minor).\(patch)"
    }

    var requirementString: String {
        "\(major).\(minor)"
    }

    static func < (lhs: PythonVersion, rhs: PythonVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    static func parse(_ raw: String) -> PythonVersion? {
        let pattern = #"(\d+)\.(\d+)(?:\.(\d+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              match.numberOfRanges >= 3,
              let majorRange = Range(match.range(at: 1), in: raw),
              let minorRange = Range(match.range(at: 2), in: raw),
              let major = Int(raw[majorRange]),
              let minor = Int(raw[minorRange]) else {
            return nil
        }
        let patch: Int
        if match.numberOfRanges > 3,
           let patchRange = Range(match.range(at: 3), in: raw),
           let parsedPatch = Int(raw[patchRange]) {
            patch = parsedPatch
        } else {
            patch = 0
        }
        return PythonVersion(major: major, minor: minor, patch: patch)
    }
}

struct PythonRequirement {
    let minimumVersion: PythonVersion
    let source: String
}

enum PythonInterpreterDiscoverySource: String {
    case repoLocalDotVenv = "repo-local (.venv)"
    case repoLocalVenv = "repo-local (venv)"
    case appPath = "app PATH"
    case loginShell = "login shell"
    case commonPath = "common path"
}

struct PythonInterpreterCandidate {
    let path: String
    let executableName: String
    let source: PythonInterpreterDiscoverySource
}

struct ProbedPythonInterpreter {
    let candidate: PythonInterpreterCandidate
    let version: PythonVersion
}

struct PythonEnvironmentResolver {
    struct RepoInspection {
        let localInterpreterPath: String?
        let hasPyproject: Bool
        let hasRequirements: Bool
        let hasSetupPy: Bool
    }

    private let preferredInterpreterNames = ["python3.12", "python3.11", "python3.10", "python3", "python"]

    func inspect(repoRoot: URL) -> RepoInspection {
        let manager = FileManager.default
        let local = localInterpreterPath(repoRoot: repoRoot)
        let pyproject = manager.fileExists(atPath: repoRoot.appendingPathComponent("pyproject.toml").path)
        let requirements = manager.fileExists(atPath: repoRoot.appendingPathComponent("requirements.txt").path)
        let setupPy = manager.fileExists(atPath: repoRoot.appendingPathComponent("setup.py").path)
        return RepoInspection(
            localInterpreterPath: local,
            hasPyproject: pyproject,
            hasRequirements: requirements,
            hasSetupPy: setupPy
        )
    }

    func localInterpreterPath(repoRoot: URL) -> String? {
        localInterpreterCandidates(repoRoot: repoRoot).first
    }

    func localInterpreterCandidates(repoRoot: URL) -> [String] {
        discoverInterpreterCandidates(repoRoot: repoRoot)
            .filter { $0.source == .repoLocalDotVenv || $0.source == .repoLocalVenv }
            .map(\.path)
    }

    func discoverInterpreterCandidates(repoRoot: URL) -> [PythonInterpreterCandidate] {
        var candidates: [PythonInterpreterCandidate] = []
        let dotVenv = repoRoot.appendingPathComponent(".venv/bin/python").path
        if FileManager.default.isExecutableFile(atPath: dotVenv) {
            candidates.append(PythonInterpreterCandidate(path: dotVenv, executableName: "python", source: .repoLocalDotVenv))
        }
        let venv = repoRoot.appendingPathComponent("venv/bin/python").path
        if FileManager.default.isExecutableFile(atPath: venv) {
            candidates.append(PythonInterpreterCandidate(path: venv, executableName: "python", source: .repoLocalVenv))
        }
        candidates.append(contentsOf: discoverSystemInterpreterCandidates())
        return deduplicated(candidates: candidates)
    }

    func discoverSystemInterpreterCandidates() -> [PythonInterpreterCandidate] {
        var candidates: [PythonInterpreterCandidate] = []
        for name in preferredInterpreterNames {
            candidates.append(contentsOf: appPathCandidates(for: name))
            candidates.append(contentsOf: loginShellCandidates(for: name))
            candidates.append(contentsOf: commonPathCandidates(for: name))
        }
        return deduplicated(candidates: candidates)
    }

    func systemInterpreterPath() -> String? {
        discoverSystemInterpreterCandidates().first?.path
    }

    func systemInterpreterCandidates() -> [String] {
        discoverSystemInterpreterCandidates().map(\.path)
    }

    func probeInterpreters(paths: [String]) -> [ProbedPythonInterpreter] {
        let candidates = deduplicated(candidates: paths.map {
            PythonInterpreterCandidate(path: $0, executableName: URL(fileURLWithPath: $0).lastPathComponent, source: .appPath)
        })
        return probeInterpreters(candidates: candidates)
    }

    func probeInterpreters(candidates: [PythonInterpreterCandidate]) -> [ProbedPythonInterpreter] {
        var probed: [ProbedPythonInterpreter] = []
        for candidate in deduplicated(candidates: candidates) {
            guard let version = pythonVersion(at: candidate.path) else { continue }
            probed.append(ProbedPythonInterpreter(candidate: candidate, version: version))
        }
        return probed
    }

    func pythonVersion(at interpreterPath: String) -> PythonVersion? {
        if let output = runInterpreter(interpreterPath, args: ["-c", "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}')"]),
           let parsed = PythonVersion.parse(output) {
            return parsed
        }
        if let output = runInterpreter(interpreterPath, args: ["--version"]),
           let parsed = PythonVersion.parse(output) {
            return parsed
        }
        return nil
    }

    func detectMinimumRequiredVersion(repoRoot: URL) -> PythonRequirement? {
        if let pyproject = requirementFromPyproject(repoRoot: repoRoot) {
            return pyproject
        }
        if let setupCfg = requirementFromSetupCfg(repoRoot: repoRoot) {
            return setupCfg
        }
        if let setupPy = requirementFromSetupPy(repoRoot: repoRoot) {
            return setupPy
        }
        if usesPEP604Syntax(repoRoot: repoRoot) {
            return PythonRequirement(
                minimumVersion: PythonVersion(major: 3, minor: 10, patch: 0),
                source: "syntax heuristic (PEP 604 union types)"
            )
        }
        return nil
    }

    private func appPathCandidates(for executable: String) -> [PythonInterpreterCandidate] {
        guard let path = findInPATH(executable) else { return [] }
        return [PythonInterpreterCandidate(path: path, executableName: executable, source: .appPath)]
    }

    private func loginShellCandidates(for executable: String) -> [PythonInterpreterCandidate] {
        shellWhichAll(executable).map {
            PythonInterpreterCandidate(path: $0, executableName: executable, source: .loginShell)
        }
    }

    private func commonPathCandidates(for executable: String) -> [PythonInterpreterCandidate] {
        let bases = ["/usr/local/bin", "/opt/homebrew/bin"]
        var results: [PythonInterpreterCandidate] = []
        for base in bases {
            let candidate = URL(fileURLWithPath: base).appendingPathComponent(executable).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                results.append(PythonInterpreterCandidate(path: candidate, executableName: executable, source: .commonPath))
            }
        }
        return results
    }

    private func deduplicated(candidates: [PythonInterpreterCandidate]) -> [PythonInterpreterCandidate] {
        var seen = Set<String>()
        var result: [PythonInterpreterCandidate] = []
        for candidate in candidates where !seen.contains(candidate.path) {
            seen.insert(candidate.path)
            result.append(candidate)
        }
        return result
    }

    private func findInPATH(_ executable: String) -> String? {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let paths = envPath.split(separator: ":").map(String.init)
        for directory in paths where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func shellWhichAll(_ executable: String) -> [String] {
        guard let output = runProcess(
            executablePath: "/bin/zsh",
            args: ["-lc", "which -a \(executable) 2>/dev/null || true"]
        ) else {
            return []
        }
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runProcess(executablePath: String, args: [String]) -> String? {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let merged = (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return merged.isEmpty ? nil : merged
    }

    private func runInterpreter(_ interpreterPath: String, args: [String]) -> String? {
        runProcess(executablePath: interpreterPath, args: args)
    }

    private func requirementFromPyproject(repoRoot: URL) -> PythonRequirement? {
        let url = repoRoot.appendingPathComponent("pyproject.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let specifier = firstCapture(pattern: #"requires-python\s*=\s*["']([^"']+)["']"#, in: text),
              let minimum = minimumVersion(from: specifier) else {
            return nil
        }
        return PythonRequirement(minimumVersion: minimum, source: "pyproject.toml (\(specifier))")
    }

    private func requirementFromSetupCfg(repoRoot: URL) -> PythonRequirement? {
        let url = repoRoot.appendingPathComponent("setup.cfg")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let raw = firstCapture(pattern: #"python_requires\s*=\s*([^\n#]+)"#, in: text) else {
            return nil
        }
        let specifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard let minimum = minimumVersion(from: specifier) else {
            return nil
        }
        return PythonRequirement(minimumVersion: minimum, source: "setup.cfg (\(specifier))")
    }

    private func requirementFromSetupPy(repoRoot: URL) -> PythonRequirement? {
        let url = repoRoot.appendingPathComponent("setup.py")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let specifier = firstCapture(pattern: #"python_requires\s*=\s*["']([^"']+)["']"#, in: text),
              let minimum = minimumVersion(from: specifier) else {
            return nil
        }
        return PythonRequirement(minimumVersion: minimum, source: "setup.py (\(specifier))")
    }

    private func minimumVersion(from specifier: String) -> PythonVersion? {
        let cleaned = specifier.replacingOccurrences(of: " ", with: "")
        if let capture = firstCapture(pattern: #">=\s*([0-9]+(?:\.[0-9]+){0,2})"#, in: cleaned),
           let parsed = PythonVersion.parse(capture) {
            return parsed
        }
        if let capture = firstCapture(pattern: #"~=\s*([0-9]+(?:\.[0-9]+){0,2})"#, in: cleaned),
           let parsed = PythonVersion.parse(capture) {
            return parsed
        }
        if let capture = firstCapture(pattern: #"==\s*([0-9]+(?:\.[0-9]+){0,2})"#, in: cleaned),
           let parsed = PythonVersion.parse(capture) {
            return parsed
        }
        if let capture = firstCapture(pattern: #">\s*([0-9]+(?:\.[0-9]+){0,2})"#, in: cleaned),
           let parsed = PythonVersion.parse(capture) {
            return bump(parsed)
        }
        if let parsed = PythonVersion.parse(cleaned) {
            return parsed
        }
        return nil
    }

    private func bump(_ version: PythonVersion) -> PythonVersion {
        if version.patch > 0 {
            return PythonVersion(major: version.major, minor: version.minor, patch: version.patch + 1)
        }
        return PythonVersion(major: version.major, minor: version.minor + 1, patch: 0)
    }

    private func usesPEP604Syntax(repoRoot: URL) -> Bool {
        let excluded = AppConstants.ignoredDirectories.union([".venv", "venv", "__pycache__"])
        guard let enumerator = FileManager.default.enumerator(
            at: repoRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return false
        }

        var scannedFiles = 0
        while let item = enumerator.nextObject() as? URL {
            let name = item.lastPathComponent
            if excluded.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            guard item.pathExtension.lowercased() == "py" else { continue }
            scannedFiles += 1
            if scannedFiles > 200 {
                break
            }
            guard let contents = try? String(contentsOf: item, encoding: .utf8) else { continue }
            if contents.contains(" | None") || contents.contains("None |") {
                return true
            }
        }
        return false
    }

    private func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }
}
