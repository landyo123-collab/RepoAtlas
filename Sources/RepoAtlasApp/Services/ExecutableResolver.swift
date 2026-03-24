import Foundation

struct ExecutableResolver {
    struct ResolvedCommand {
        let command: String
        let args: [String]
        let environmentOverrides: [String: String]
        let resolvedExecutableMessage: String?
        let environmentMessage: String?
    }

    private let pythonResolver = PythonRunEnvironmentResolver()
    private let packageManagerResolver = PackageManagerResolver()

    func resolve(command: String, args: [String], repoRoot: URL) throws -> ResolvedCommand {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ResolvedCommand(
                command: command,
                args: args,
                environmentOverrides: [:],
                resolvedExecutableMessage: nil,
                environmentMessage: nil
            )
        }

        let executableName = URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
        if executableName.hasPrefix("python") {
            let resolved = try pythonResolver.resolve(command: trimmed, args: args, repoRoot: repoRoot)
            return ResolvedCommand(
                command: resolved.executablePath,
                args: args,
                environmentOverrides: resolved.environmentOverrides,
                resolvedExecutableMessage: resolved.executableMessage,
                environmentMessage: resolved.environmentMessage
            )
        }

        if packageManagerResolver.supports(executable: executableName) {
            let resolved = try packageManagerResolver.resolve(executable: executableName)
            return ResolvedCommand(
                command: resolved.executablePath,
                args: args,
                environmentOverrides: resolved.environmentOverrides,
                resolvedExecutableMessage: resolved.executableMessage,
                environmentMessage: resolved.environmentMessage
            )
        }

        return ResolvedCommand(
            command: command,
            args: args,
            environmentOverrides: [:],
            resolvedExecutableMessage: nil,
            environmentMessage: nil
        )
    }
}

private enum PackageManagerDiscoverySource: String {
    case appPath = "app PATH"
    case loginShell = "login shell"
    case commonPath = "common path"
}

private enum PackageManagerTool: String, CaseIterable {
    case node
    case npm
    case pnpm
    case yarn
}

private struct PackageManagerCandidate {
    let tool: PackageManagerTool
    let executableName: String
    let path: String
    let source: PackageManagerDiscoverySource
}

private struct PackageManagerDiscoverySnapshot {
    let candidatesByTool: [PackageManagerTool: [PackageManagerCandidate]]
    let loginShellPath: String?
}

private struct ShellDiscoveryResult {
    let pathsByTool: [PackageManagerTool: [String]]
    let path: String?
}

private struct ExecutionEnvironment {
    let overrides: [String: String]
    let sourceDescription: String
}

private struct PackageManagerResolver {
    struct Resolution {
        let executablePath: String
        let environmentOverrides: [String: String]
        let executableMessage: String
        let environmentMessage: String?
    }

    enum ResolutionError: LocalizedError {
        case notFound(executable: String)
        case missingNodeRuntime(packageManager: String)

        var errorDescription: String? {
            switch self {
            case let .notFound(executable):
                return "No suitable \(executable) executable found (searched app PATH, login shell, and common paths)."
            case .missingNodeRuntime:
                return "Package manager was found, but Node.js was not available in the execution environment."
            }
        }
    }

    private let supportedTools: Set<PackageManagerTool> = [.node, .npm, .pnpm, .yarn]

    func supports(executable: String) -> Bool {
        PackageManagerTool(rawValue: executable.lowercased()).map(supportedTools.contains) ?? false
    }

    func resolve(executable: String) throws -> Resolution {
        let normalized = executable.lowercased()
        guard let requestedTool = PackageManagerTool(rawValue: normalized) else {
            throw ResolutionError.notFound(executable: normalized)
        }
        let snapshot = discoverSnapshot()
        guard let selected = snapshot.candidatesByTool[requestedTool]?.first else {
            throw ResolutionError.notFound(executable: normalized)
        }

        let selectedNode: PackageManagerCandidate
        if requestedTool == .node {
            selectedNode = selected
        } else {
            guard let node = bestNodeCandidate(for: selected, snapshot: snapshot) else {
                throw ResolutionError.missingNodeRuntime(packageManager: requestedTool.rawValue)
            }
            selectedNode = node
        }

        let environment = buildExecutionEnvironment(
            selectedExecutable: selected,
            selectedNode: selectedNode,
            snapshot: snapshot
        )

        var executionLines: [String] = [
            "Resolved executable: \(selected.path) (source: \(selected.source.rawValue))"
        ]
        if requestedTool != .node {
            executionLines.append("Resolved node: \(selectedNode.path) (source: \(selectedNode.source.rawValue))")
        }

        var details: [String] = [
            "Environment source: \(environment.sourceDescription)"
        ]
        if let effectivePath = environment.overrides["PATH"] {
            details.append("Effective PATH: \(effectivePath)")
        }

        if let selectedCandidates = snapshot.candidatesByTool[requestedTool], !selectedCandidates.isEmpty {
            details.append(candidateSummary(label: requestedTool.rawValue, candidates: selectedCandidates))
        }
        if requestedTool != .node, let nodeCandidates = snapshot.candidatesByTool[.node], !nodeCandidates.isEmpty {
            details.append(candidateSummary(label: "node", candidates: nodeCandidates))
        }

        return Resolution(
            executablePath: selected.path,
            environmentOverrides: environment.overrides,
            executableMessage: executionLines.joined(separator: "\n"),
            environmentMessage: details.joined(separator: "\n")
        )
    }

    private func discoverSnapshot() -> PackageManagerDiscoverySnapshot {
        var byTool: [PackageManagerTool: [PackageManagerCandidate]] = [:]
        for tool in PackageManagerTool.allCases {
            byTool[tool] = []
        }

        for tool in PackageManagerTool.allCases {
            byTool[tool, default: []].append(contentsOf: appPathCandidates(for: tool))
        }

        let shellResult = loginShellDiscovery()
        for tool in PackageManagerTool.allCases {
            let shellPaths = shellResult.pathsByTool[tool] ?? []
            let shellCandidates = shellPaths.map {
                PackageManagerCandidate(tool: tool, executableName: tool.rawValue, path: $0, source: .loginShell)
            }
            byTool[tool, default: []].append(contentsOf: shellCandidates)
        }

        for tool in PackageManagerTool.allCases {
            byTool[tool, default: []].append(contentsOf: commonPathCandidates(for: tool))
        }

        for tool in PackageManagerTool.allCases {
            byTool[tool] = deduplicated(byTool[tool] ?? [])
        }

        return PackageManagerDiscoverySnapshot(
            candidatesByTool: byTool,
            loginShellPath: shellResult.path
        )
    }

    private func bestNodeCandidate(
        for packageManager: PackageManagerCandidate,
        snapshot: PackageManagerDiscoverySnapshot
    ) -> PackageManagerCandidate? {
        let nodes = snapshot.candidatesByTool[.node] ?? []
        guard !nodes.isEmpty else { return nil }

        let managerDirectory = directoryPath(for: packageManager.path)

        if let exact = nodes.first(where: { $0.source == packageManager.source && directoryPath(for: $0.path) == managerDirectory }) {
            return exact
        }
        if let sameSource = nodes.first(where: { $0.source == packageManager.source }) {
            return sameSource
        }
        if let sameDirectory = nodes.first(where: { directoryPath(for: $0.path) == managerDirectory }) {
            return sameDirectory
        }
        return nodes.first
    }

    private func buildExecutionEnvironment(
        selectedExecutable: PackageManagerCandidate,
        selectedNode: PackageManagerCandidate,
        snapshot: PackageManagerDiscoverySnapshot
    ) -> ExecutionEnvironment {
        let appPathComponents = splitPath(ProcessInfo.processInfo.environment["PATH"] ?? "")
        let selectedExecutableDirectory = directoryPath(for: selectedExecutable.path)
        let selectedNodeDirectory = directoryPath(for: selectedNode.path)

        var combined: [String] = [selectedExecutableDirectory, selectedNodeDirectory]
        var sourceDescription = selectedExecutable.source.rawValue

        if selectedExecutable.source == .loginShell, let shellPath = snapshot.loginShellPath, !shellPath.isEmpty {
            combined.append(contentsOf: splitPath(shellPath))
            sourceDescription = "login shell"
        }
        combined.append(contentsOf: appPathComponents)

        let effectivePath = deduplicatedPathComponents(combined).joined(separator: ":")
        var overrides: [String: String] = [:]
        if !effectivePath.isEmpty {
            overrides["PATH"] = effectivePath
        }

        return ExecutionEnvironment(overrides: overrides, sourceDescription: sourceDescription)
    }

    private func appPathCandidates(for tool: PackageManagerTool) -> [PackageManagerCandidate] {
        guard let path = findInPATH(tool.rawValue) else { return [] }
        return [PackageManagerCandidate(tool: tool, executableName: tool.rawValue, path: path, source: .appPath)]
    }

    private func commonPathCandidates(for tool: PackageManagerTool) -> [PackageManagerCandidate] {
        let bases = ["/usr/local/bin", "/opt/homebrew/bin"]
        return bases.compactMap { base in
            let candidatePath = URL(fileURLWithPath: base).appendingPathComponent(tool.rawValue).path
            guard FileManager.default.isExecutableFile(atPath: candidatePath) else { return nil }
            return PackageManagerCandidate(tool: tool, executableName: tool.rawValue, path: candidatePath, source: .commonPath)
        }
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

    private func loginShellDiscovery() -> ShellDiscoveryResult {
        let script = "which -a node npm pnpm yarn 2>/dev/null || true; printf '__RA_PATH__%s\\n' \"$PATH\""
        guard let output = runProcess(executablePath: "/bin/zsh", args: ["-lc", script]) else {
            return ShellDiscoveryResult(pathsByTool: [:], path: nil)
        }

        var byTool: [PackageManagerTool: [String]] = [:]
        var discoveredPath: String?
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines {
            if line.hasPrefix("__RA_PATH__") {
                discoveredPath = String(line.dropFirst("__RA_PATH__".count))
                continue
            }
            guard line.hasPrefix("/") else { continue }
            guard FileManager.default.isExecutableFile(atPath: line) else { continue }
            let name = URL(fileURLWithPath: line).lastPathComponent.lowercased()
            guard let tool = PackageManagerTool(rawValue: name) else { continue }
            byTool[tool, default: []].append(line)
        }

        for tool in PackageManagerTool.allCases {
            byTool[tool] = deduplicatedPaths(byTool[tool] ?? [])
        }

        return ShellDiscoveryResult(pathsByTool: byTool, path: discoveredPath)
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

    private func candidateSummary(label: String, candidates: [PackageManagerCandidate]) -> String {
        let lines = candidates.map { candidate in
            "- \(candidate.path) [\(candidate.source.rawValue)]"
        }
        return "Detected \(label) candidates:\n" + lines.joined(separator: "\n")
    }

    private func directoryPath(for executablePath: String) -> String {
        URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
    }

    private func splitPath(_ path: String) -> [String] {
        path
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func deduplicatedPathComponents(_ components: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for component in components where !component.isEmpty && !seen.contains(component) {
            seen.insert(component)
            result.append(component)
        }
        return result
    }

    private func deduplicatedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths where !seen.contains(path) {
            seen.insert(path)
            result.append(path)
        }
        return result
    }

    private func deduplicated(_ candidates: [PackageManagerCandidate]) -> [PackageManagerCandidate] {
        var seen = Set<String>()
        var results: [PackageManagerCandidate] = []
        for candidate in candidates where !seen.contains(candidate.path) {
            seen.insert(candidate.path)
            results.append(candidate)
        }
        return results
    }
}
