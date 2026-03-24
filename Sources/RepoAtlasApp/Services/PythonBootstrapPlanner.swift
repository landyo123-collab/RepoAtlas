import Foundation

struct BootstrapCommand {
    let command: String
    let args: [String]

    var display: String {
        ([command] + args).map(Self.quoteIfNeeded).joined(separator: " ")
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        guard value.contains(" ") || value.contains("\"") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

struct PythonBootstrapPlan {
    let reason: String
    let commands: [BootstrapCommand]
}

struct PythonBootstrapPlanner {
    enum Trigger {
        case proactive
        case failure(kind: LaunchFailureKind)
    }

    enum PythonRunShape: String {
        case directScriptRun
        case moduleRun
        case installablePackageRun
    }

    enum BootstrapError: LocalizedError {
        case noSystemPython
        case noCompatibleSystemPython(requiredVersion: String, detected: [String])

        var errorDescription: String? {
            switch self {
            case .noSystemPython:
                return "No suitable Python interpreter found for setup (python3.12, python3.11, python3.10, python3, python)."
            case let .noCompatibleSystemPython(requiredVersion, detected):
                if detected.isEmpty {
                    return "This repo appears to require Python \(requiredVersion)+ for setup, but no compatible interpreter was found."
                }
                return "This repo appears to require Python \(requiredVersion)+ for setup, but no compatible interpreter was found. Detected: \(detected.joined(separator: ", "))."
            }
        }
    }

    private let environmentResolver = PythonEnvironmentResolver()

    func planIfNeeded(
        repoRoot: URL,
        command: String,
        args: [String],
        trigger: Trigger = .proactive
    ) throws -> PythonBootstrapPlan? {
        let inspection = environmentResolver.inspect(repoRoot: repoRoot)
        let shape = runShape(command: command, args: args, repoRoot: repoRoot)
        let hasRequirementsDependencies = requirementsHasRuntimeDependencies(repoRoot: repoRoot)
        let hasPyprojectDependencies = pyprojectHasRuntimeDependencies(repoRoot: repoRoot)
        let hasSetupDependencies = setupHasRuntimeDependencies(repoRoot: repoRoot)
        let hasDependencyManifest = hasRequirementsDependencies || hasPyprojectDependencies || hasSetupDependencies
        let hasInstallableManifest = inspection.hasPyproject || inspection.hasSetupPy || setupCfgExists(repoRoot: repoRoot)

        switch trigger {
        case .proactive:
            // Avoid preemptive setup for direct script runs and stdlib/empty-dependency repos.
            guard shape != .directScriptRun else { return nil }
            guard hasDependencyManifest else { return nil }
        case .failure(let kind):
            switch kind {
            case .missingDependency:
                // Keep bootstrap available after concrete dependency failures.
                break
            case .missingInterpreter:
                guard hasDependencyManifest || (shape != .directScriptRun && hasInstallableManifest) else { return nil }
            default:
                return nil
            }
        }

        if inspection.localInterpreterPath != nil {
            return nil
        }

        let shouldEditableInstall = hasInstallableManifest && !hasRequirementsDependencies
        let shouldRequirementsInstall = inspection.hasRequirements && !shouldEditableInstall
        guard shouldEditableInstall || shouldRequirementsInstall else {
            return nil
        }

        let requirement = environmentResolver.detectMinimumRequiredVersion(repoRoot: repoRoot)
        let systemCandidates = environmentResolver.discoverSystemInterpreterCandidates()
        let probed = environmentResolver.probeInterpreters(candidates: systemCandidates)
        guard !probed.isEmpty else {
            throw BootstrapError.noSystemPython
        }
        let bootstrapPython: String
        if let requirement {
            guard let selected = probed.first(where: { $0.version >= requirement.minimumVersion }) else {
                throw BootstrapError.noCompatibleSystemPython(
                    requiredVersion: requirement.minimumVersion.requirementString,
                    detected: probed.map { "\($0.candidate.path) (\($0.version.displayString), \($0.candidate.source.rawValue))" }
                )
            }
            bootstrapPython = selected.candidate.path
        } else {
            bootstrapPython = probed[0].candidate.path
        }

        var commands: [BootstrapCommand] = [
            BootstrapCommand(command: bootstrapPython, args: ["-m", "venv", ".venv"]),
            BootstrapCommand(command: ".venv/bin/python", args: ["-m", "pip", "install", "--upgrade", "pip"])
        ]

        let reason: String
        if shouldEditableInstall {
            commands.append(BootstrapCommand(command: ".venv/bin/python", args: ["-m", "pip", "install", "-e", "."]))
            reason = "Environment setup required: install project package into a repo-local .venv."
        } else {
            commands.append(BootstrapCommand(command: ".venv/bin/python", args: ["-m", "pip", "install", "-r", "requirements.txt"]))
            reason = "Environment setup required: install requirements into a repo-local .venv."
        }

        return PythonBootstrapPlan(reason: reason, commands: commands)
    }

    private func runShape(command: String, args: [String], repoRoot: URL) -> PythonRunShape {
        let executableName = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        guard executableName.hasPrefix("python") else {
            return .installablePackageRun
        }

        if let module = moduleInvocation(args: args), !module.isEmpty {
            return .moduleRun
        }
        if let script = directScriptPath(args: args), scriptIsPythonFile(script, repoRoot: repoRoot) {
            return .directScriptRun
        }
        return .installablePackageRun
    }

    private func moduleInvocation(args: [String]) -> String? {
        guard let index = args.firstIndex(of: "-m"), args.indices.contains(index + 1) else { return nil }
        let module = args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return module.isEmpty ? nil : module
    }

    private func directScriptPath(args: [String]) -> String? {
        var index = 0
        while index < args.count {
            let current = args[index]
            if current == "-m" || current == "-c" {
                return nil
            }
            if current.hasPrefix("-") {
                // Options that consume a value.
                if (current == "-W" || current == "-X"), args.indices.contains(index + 1) {
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func scriptIsPythonFile(_ script: String, repoRoot: URL) -> Bool {
        guard script.lowercased().hasSuffix(".py") else { return false }
        if script.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: script)
        }
        return FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(script).path)
    }

    private func requirementsHasRuntimeDependencies(repoRoot: URL) -> Bool {
        let url = repoRoot.appendingPathComponent("requirements.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { line in
                !line.isEmpty && !line.hasPrefix("#")
            }
    }

    private func pyprojectHasRuntimeDependencies(repoRoot: URL) -> Bool {
        let url = repoRoot.appendingPathComponent("pyproject.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }

        if let pep621 = firstCapture(
            pattern: #"(?s)\[project\].*?dependencies\s*=\s*\[(.*?)\]"#,
            in: text
        ), listHasQuotedEntries(pep621) {
            return true
        }

        var inPoetryDependencies = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inPoetryDependencies = line == "[tool.poetry.dependencies]"
                continue
            }
            guard inPoetryDependencies else { continue }
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            if !key.isEmpty, key != "python" {
                return true
            }
        }
        return false
    }

    private func setupHasRuntimeDependencies(repoRoot: URL) -> Bool {
        if setupCfgHasInstallRequires(repoRoot: repoRoot) {
            return true
        }
        if setupPyHasInstallRequires(repoRoot: repoRoot) {
            return true
        }
        return false
    }

    private func setupCfgExists(repoRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("setup.cfg").path)
    }

    private func setupCfgHasInstallRequires(repoRoot: URL) -> Bool {
        let url = repoRoot.appendingPathComponent("setup.cfg")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        guard let block = firstCapture(
            pattern: #"(?s)\[options\].*?install_requires\s*=\s*(.*?)(?:\n\s*\[|$)"#,
            in: text
        ) else {
            return false
        }
        return block
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { line in
                !line.isEmpty && !line.hasPrefix("#")
            }
    }

    private func setupPyHasInstallRequires(repoRoot: URL) -> Bool {
        let url = repoRoot.appendingPathComponent("setup.py")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        guard let list = firstCapture(
            pattern: #"(?s)install_requires\s*=\s*\[(.*?)\]"#,
            in: text
        ) else {
            return false
        }
        return listHasQuotedEntries(list)
    }

    private func listHasQuotedEntries(_ raw: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"['"]([^'"]+)['"]"#) else { return false }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return regex.firstMatch(in: raw, range: range) != nil
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
