import Foundation

struct PythonRunEnvironmentResolver {
    private enum PythonRunShape {
        case directScriptRun
        case moduleRun
        case other
    }

    struct Resolution {
        let executablePath: String
        let environmentOverrides: [String: String]
        let executableMessage: String
        let environmentMessage: String?
    }

    enum ResolutionError: LocalizedError {
        case noPythonInterpreterFound
        case noCompatiblePythonInterpreter(requiredVersion: String, detected: [String])

        var errorDescription: String? {
            switch self {
            case .noPythonInterpreterFound:
                return "No suitable Python interpreter found (.venv/bin/python, venv/bin/python, python3.12, python3.11, python3.10, python3, python)."
            case let .noCompatiblePythonInterpreter(requiredVersion, detected):
                if detected.isEmpty {
                    return "This repo appears to require Python \(requiredVersion)+, but no compatible interpreter was found."
                }
                return "This repo appears to require Python \(requiredVersion)+, but no compatible interpreter was found. Detected: \(detected.joined(separator: ", "))."
            }
        }
    }

    private let environmentResolver = PythonEnvironmentResolver()

    func resolve(command: String, args: [String], repoRoot: URL) throws -> Resolution {
        let requirement = environmentResolver.detectMinimumRequiredVersion(repoRoot: repoRoot)
        let minimumVersion = requirement?.minimumVersion

        let candidates = environmentResolver.discoverInterpreterCandidates(repoRoot: repoRoot)
        let probed = environmentResolver.probeInterpreters(candidates: candidates)

        guard !probed.isEmpty else {
            throw ResolutionError.noPythonInterpreterFound
        }

        let selected = probed.first { interpreter in
            guard let minimumVersion else { return true }
            return interpreter.version >= minimumVersion
        }

        guard let selected else {
            let versionByPath = Dictionary(
                probed.map { ($0.candidate.path, $0.version) },
                uniquingKeysWith: { first, _ in first }
            )
            let detected = candidates.map { candidate in
                let versionLabel = versionByPath[candidate.path].map { $0.displayString } ?? "unknown"
                return "\(candidate.path) (\(versionLabel), \(candidate.source.rawValue))"
            }
            throw ResolutionError.noCompatiblePythonInterpreter(
                requiredVersion: requirement?.minimumVersion.requirementString ?? "unknown",
                detected: detected
            )
        }

        let usedLocalInterpreter = selected.candidate.source == .repoLocalDotVenv || selected.candidate.source == .repoLocalVenv
        var env: [String: String] = [:]
        var messages: [String] = []
        let shape = runShape(args: args, repoRoot: repoRoot)

        let versionByPath = Dictionary(
            probed.map { ($0.candidate.path, $0.version) },
            uniquingKeysWith: { first, _ in first }
        )

        if let requirement {
            messages.append("Detected minimum required Python: \(requirement.minimumVersion.requirementString)+ (\(requirement.source))")
        }

        let candidateLines = candidates.map { candidate -> String in
            let versionLabel = versionByPath[candidate.path].map { $0.displayString } ?? "unknown"
            return "- \(candidate.executableName): \(candidate.path) [\(candidate.source.rawValue), Python \(versionLabel)]"
        }
        if !candidateLines.isEmpty {
            messages.append("Detected interpreter candidates:\n" + candidateLines.joined(separator: "\n"))
        }

        if !usedLocalInterpreter,
           let module = pythonModuleInvocation(args: args),
           let srcPath = srcLayoutPath(for: module, repoRoot: repoRoot) {
            env["PYTHONPATH"] = srcPath
            messages.append("Environment override: PYTHONPATH=\(srcPath)")
        }
        if shape == .directScriptRun {
            env["PYTHONUNBUFFERED"] = "1"
            messages.append("Environment override: PYTHONUNBUFFERED=1 (direct script run)")
        }

        return Resolution(
            executablePath: selected.candidate.path,
            environmentOverrides: env,
            executableMessage: "Resolved executable: \(selected.candidate.path) (Python \(selected.version.displayString), source: \(selected.candidate.source.rawValue))",
            environmentMessage: messages.isEmpty ? nil : messages.joined(separator: "\n")
        )
    }

    private func pythonModuleInvocation(args: [String]) -> String? {
        guard args.count >= 2, args[0] == "-m" else { return nil }
        let module = args[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !module.isEmpty else { return nil }
        return module
    }

    private func runShape(args: [String], repoRoot: URL) -> PythonRunShape {
        if pythonModuleInvocation(args: args) != nil {
            return .moduleRun
        }
        guard let script = pythonScriptInvocation(args: args), scriptIsPythonFile(script, repoRoot: repoRoot) else {
            return .other
        }
        return .directScriptRun
    }

    private func pythonScriptInvocation(args: [String]) -> String? {
        var index = 0
        while index < args.count {
            let current = args[index]
            if current == "-m" || current == "-c" {
                return nil
            }
            if current.hasPrefix("-") {
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

    private func srcLayoutPath(for module: String, repoRoot: URL) -> String? {
        let rootModule = module.split(separator: ".").first.map(String.init) ?? module
        guard !rootModule.isEmpty else { return nil }

        let srcURL = repoRoot.appendingPathComponent("src")
        let moduleURL = srcURL.appendingPathComponent(rootModule)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: moduleURL.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return srcURL.path
    }
}
