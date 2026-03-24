import Foundation

struct WebRunDetection {
    let plan: LaunchpadRunPlan?
    let failureReason: String?
}

struct WebRunDetector {
    func detect(repo: RepoModel) -> WebRunDetection {
        let root = URL(fileURLWithPath: repo.rootPath)
        let packageURL = root.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            return WebRunDetection(plan: nil, failureReason: nil)
        }

        guard let packageData = try? Data(contentsOf: packageURL),
              let json = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any] else {
            return WebRunDetection(plan: nil, failureReason: "package.json exists but could not be parsed.")
        }

        let scripts = (json["scripts"] as? [String: Any]) ?? [:]
        let scriptPreference = ["dev", "start", "preview"]
        guard let selectedScript = scriptPreference.first(where: { scripts[$0] != nil }) else {
            return WebRunDetection(plan: nil, failureReason: "Could not detect runnable web script in package.json.")
        }

        guard hasWebSignals(root: root, repo: repo, scripts: scripts) else {
            return WebRunDetection(plan: nil, failureReason: nil)
        }

        let manager = choosePackageManager(root: root)
        let scriptCommand = String(describing: scripts[selectedScript] ?? "")
        let inferredPort = inferLikelyPort(root: root, scripts: scripts, scriptCommand: scriptCommand)
        let framework = inferFramework(root: root, scripts: scripts, scriptCommand: scriptCommand)

        let plan = LaunchpadRunPlan(
            projectType: "Node/Web (\(framework))",
            command: manager,
            args: ["run", selectedScript],
            workingDirectory: repo.rootPath,
            outputMode: .webPreview,
            port: inferredPort,
            confidence: 0.92,
            reason: "Local web detector found package.json, selected '\(selectedScript)' script, and matched web app signals.",
            launchNotes: "Detected package manager: \(manager).",
            isRunnable: true,
            blocker: nil,
            appBundlePath: nil
        )

        return WebRunDetection(plan: plan, failureReason: nil)
    }

    private func choosePackageManager(root: URL) -> String {
        let manager = FileManager.default
        if manager.fileExists(atPath: root.appendingPathComponent("pnpm-lock.yaml").path) {
            return "pnpm"
        }
        if manager.fileExists(atPath: root.appendingPathComponent("yarn.lock").path) {
            return "yarn"
        }
        return "npm"
    }

    private func hasWebSignals(root: URL, repo: RepoModel, scripts: [String: Any]) -> Bool {
        let manager = FileManager.default
        let directSignals = [
            "vite.config.ts", "vite.config.js", "vite.config.mjs",
            "next.config.js", "next.config.mjs", "next.config.ts",
            "svelte.config.js", "svelte.config.ts",
            "astro.config.mjs", "astro.config.ts",
            "angular.json",
            "src/main.ts", "src/main.tsx", "src/index.tsx",
            "index.html"
        ]
        if directSignals.contains(where: { manager.fileExists(atPath: root.appendingPathComponent($0).path) }) {
            return true
        }
        if manager.fileExists(atPath: root.appendingPathComponent("public").path) {
            return true
        }

        let languageSignals = ["HTML", "CSS", "TypeScript", "JavaScript"]
        if repo.summary.languageCounts.keys.contains(where: { languageSignals.contains($0) }) {
            return true
        }

        let scriptText = scripts.values.map { String(describing: $0).lowercased() }.joined(separator: " ")
        if scriptText.contains("vite") || scriptText.contains("next") || scriptText.contains("astro") || scriptText.contains("webpack") {
            return true
        }
        return false
    }

    private func inferLikelyPort(root: URL, scripts: [String: Any], scriptCommand: String) -> Int? {
        let manager = FileManager.default
        let command = scriptCommand.lowercased()

        if manager.fileExists(atPath: root.appendingPathComponent("vite.config.ts").path)
            || manager.fileExists(atPath: root.appendingPathComponent("vite.config.js").path)
            || manager.fileExists(atPath: root.appendingPathComponent("vite.config.mjs").path)
            || command.contains("vite") {
            return 5173
        }

        if manager.fileExists(atPath: root.appendingPathComponent("next.config.js").path)
            || manager.fileExists(atPath: root.appendingPathComponent("next.config.mjs").path)
            || manager.fileExists(atPath: root.appendingPathComponent("next.config.ts").path)
            || command.contains("next") {
            return 3000
        }

        if manager.fileExists(atPath: root.appendingPathComponent("astro.config.mjs").path)
            || manager.fileExists(atPath: root.appendingPathComponent("astro.config.ts").path)
            || command.contains("astro") {
            return 4321
        }

        return nil
    }

    private func inferFramework(root: URL, scripts: [String: Any], scriptCommand: String) -> String {
        let manager = FileManager.default
        let command = scriptCommand.lowercased()
        if manager.fileExists(atPath: root.appendingPathComponent("vite.config.ts").path)
            || manager.fileExists(atPath: root.appendingPathComponent("vite.config.js").path)
            || command.contains("vite") {
            return "Vite"
        }
        if manager.fileExists(atPath: root.appendingPathComponent("next.config.js").path) || command.contains("next") {
            return "Next"
        }
        if manager.fileExists(atPath: root.appendingPathComponent("astro.config.mjs").path) || command.contains("astro") {
            return "Astro"
        }
        return "Generic Web"
    }
}
