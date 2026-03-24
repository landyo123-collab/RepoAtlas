import Foundation

// MARK: - File type (what the file IS)

enum FileType: String {
    case source
    case config
    case docs
    case test
    case entrypoint
    case build
    case data
    case asset
    case generated
    case unknown
}

// MARK: - Corpus tier (who owns the file)

enum CorpusTier: String {
    case firstParty          // normal project code
    case projectSupport      // CI/CD, root configs, docs, lockfiles
    case externalDependency  // vendored / installed third-party code
    case generatedArtifact   // machine output, caches, build products
    case binaryOrIgnored     // binary assets, cache files
}

// MARK: - Classification result

struct FileClassification {
    let fileType: FileType
    let corpusTier: CorpusTier
    let roleTags: [String]
}

// MARK: - Classifier

struct FileClassifier {

    // Path components that indicate external/vendored dependency directories
    private static let externalDependencyMarkers: Set<String> = [
        "venv", ".venv", "env",
        "site-packages",
        "node_modules",
        "pods",
        "carthage",
        "vendor", "vendors",
        "third_party", "third-party", "thirdparty",
        "external",
        "bower_components",
        ".eggs",
        ".tox",
        "jspm_packages",
        ".pub-cache", ".dart_tool",
        ".bundle",       // Ruby bundler
    ]

    // Path components that indicate generated/build artifact directories
    private static let generatedArtifactMarkers: Set<String> = [
        "dist",
        "build", ".build",
        "deriveddata",
        "__pycache__",
        ".cache", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        "coverage",
        ".next", ".nuxt",
        "target",        // Rust/Maven
        "out",
        ".gradle",
        ".terraform",
        ".turbo",
        ".parcel-cache",
        ".egg-info",
    ]

    // MARK: - Tier classification (based on path alone)

    func classifyTier(relativePath: String) -> CorpusTier {
        // Normalize path for component matching: "/path/component/"
        let searchable = "/" + relativePath.lowercased() + "/"
        let components = Set(
            relativePath.lowercased()
                .split(separator: "/")
                .map(String.init)
        )

        // Check external dependency markers
        for marker in Self.externalDependencyMarkers {
            if searchable.contains("/\(marker)/") {
                return .externalDependency
            }
        }

        // Check generated artifact markers
        for marker in Self.generatedArtifactMarkers {
            if searchable.contains("/\(marker)/") {
                return .generatedArtifact
            }
        }

        // Binary/ignored detection by extension
        let ext = (relativePath as NSString).pathExtension.lowercased()
        let binaryExts: Set<String> = ["png", "jpg", "jpeg", "gif", "ico", "webp",
                                        "mp3", "mp4", "wav", "ogg", "flac",
                                        "ttf", "woff", "woff2", "eot", "otf",
                                        "zip", "tar", "gz", "bz2", "xz",
                                        "bin", "exe", "dll", "so", "dylib",
                                        "pdf", "doc", "docx", "xls", "xlsx"]
        if binaryExts.contains(ext) {
            return .binaryOrIgnored
        }

        // Minified files
        let name = (relativePath as NSString).lastPathComponent.lowercased()
        if name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.hasSuffix(".bundle.js") {
            return .generatedArtifact
        }

        // Lockfiles → projectSupport (not firstParty, but not external)
        if name.hasSuffix(".lock") || name == "package-lock.json" || name == "yarn.lock"
            || name == "pnpm-lock.yaml" || name == "pipfile.lock" || name == "cargo.lock"
            || name == "gemfile.lock" || name == "cartfile.resolved" || name == "podfile.lock" {
            return .projectSupport
        }

        // CI/build system files → projectSupport
        if components.contains(".github") || components.contains(".circleci")
            || components.contains(".gitlab-ci") || name == "jenkinsfile" || name == "procfile" {
            return .projectSupport
        }

        // Everything else is first-party
        return .firstParty
    }

    // MARK: - Full classification

    func classify(relativePath: String, name: String, ext: String, language: String) -> FileClassification {
        var tags: [String] = []
        let lower = relativePath.lowercased()
        let lowerName = name.lowercased()

        // Determine corpus tier first
        let tier = classifyTier(relativePath: relativePath)

        // Always add tier as a tag for searchability
        tags.append(tier.rawValue)

        // Entrypoint detection
        let entrypointNames: Set<String> = ["main", "app", "index", "__main__", "program", "application"]
        let baseName = (lowerName as NSString).deletingPathExtension
        if entrypointNames.contains(baseName) {
            tags.append("entrypoint")
        }

        // Test detection
        if lower.contains("/test") || lower.contains("/spec") || lower.contains("/__tests__/")
            || lowerName.hasPrefix("test_") || lowerName.hasSuffix("_test.\(ext)")
            || lowerName.hasSuffix("test.\(ext)") || lowerName.hasSuffix("tests.\(ext)")
            || lowerName.hasSuffix("spec.\(ext)") || lowerName.hasSuffix("_spec.\(ext)") {
            tags.append("test")
        }

        // Config detection
        let configNames: Set<String> = [
            "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
            "tsconfig.json", "jsconfig.json", ".eslintrc", ".eslintrc.json", ".prettierrc",
            "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "pipfile", "pipfile.lock",
            "cargo.toml", "cargo.lock", "gemfile", "gemfile.lock",
            "podfile", "podfile.lock", "cartfile", "cartfile.resolved",
            "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
            "pom.xml", "build.sbt",
            "makefile", "cmakelists.txt", "meson.build",
            "docker-compose.yml", "docker-compose.yaml", "dockerfile",
            ".env", ".env.example", ".env.local",
            "info.plist", ".gitignore", ".dockerignore",
            "package.swift", "project.yml", "project.pbxproj",
            "webpack.config.js", "vite.config.ts", "vite.config.js",
            "next.config.js", "next.config.mjs", "astro.config.mjs",
            "tailwind.config.js", "tailwind.config.ts", "postcss.config.js",
            "babel.config.js", ".babelrc", "rollup.config.js",
            "jest.config.js", "jest.config.ts", "vitest.config.ts",
            "angular.json", "nx.json", "turbo.json"
        ]
        if configNames.contains(lowerName) {
            tags.append("config")
        }
        let configExts: Set<String> = ["ini", "cfg", "conf", "toml", "env", "plist"]
        if configExts.contains(ext) {
            tags.append("config")
        }

        // Docs detection
        if lowerName.hasPrefix("readme") || lowerName == "changelog" || lowerName == "changelog.md"
            || lowerName == "contributing.md" || lowerName == "license" || lowerName == "license.md"
            || lower.contains("/docs/") || lower.contains("/documentation/") {
            tags.append("docs")
        }
        if ext == "md" && !tags.contains("docs") {
            tags.append("docs")
        }

        // Build / CI
        if lower.contains("/.github/") || lower.contains("/.circleci/") || lower.contains("/.gitlab-ci")
            || lowerName == "jenkinsfile" || lowerName == "procfile" {
            tags.append("build")
        }

        // Data
        let dataExts: Set<String> = ["csv", "sql", "sqlite", "db"]
        if dataExts.contains(ext) {
            tags.append("data")
        }

        // Asset
        let assetExts: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "ico", "webp", "mp3", "mp4", "wav", "ttf", "woff", "woff2", "eot"]
        if assetExts.contains(ext) {
            tags.append("asset")
        }

        // Generated
        if lower.contains("/generated/") || lower.contains(".generated.") || lower.contains("/dist/")
            || lower.contains("/build/") || lower.contains(".min.js") || lower.contains(".min.css")
            || lowerName.hasSuffix(".lock") {
            tags.append("generated")
        }

        // Source (if nothing else strongly applies)
        let sourceExts: Set<String> = ["swift", "py", "js", "jsx", "ts", "tsx", "java", "kt", "kts",
                                        "go", "rs", "rb", "php", "c", "cpp", "cc", "h", "hpp", "m", "mm",
                                        "cs", "scala", "clj", "ex", "exs", "hs", "lua", "r",
                                        "html", "css", "scss", "sass", "less", "vue", "svelte"]
        if sourceExts.contains(ext) && !tags.contains("test") && !tags.contains("config") {
            tags.append("source")
        }

        // Manifest (subset of config that describes the project shape)
        let manifestNames: Set<String> = [
            "package.json", "package.swift", "cargo.toml", "gemfile", "pyproject.toml",
            "requirements.txt", "build.gradle", "build.gradle.kts", "pom.xml", "setup.py",
            "podfile", "go.mod", "composer.json"
        ]
        if manifestNames.contains(lowerName) {
            tags.append("manifest")
        }

        // Determine primary type from tags
        let fileType: FileType
        if tags.contains("entrypoint") { fileType = .entrypoint }
        else if tags.contains("test") { fileType = .test }
        else if tags.contains("generated") { fileType = .generated }
        else if tags.contains("asset") { fileType = .asset }
        else if tags.contains("data") { fileType = .data }
        else if tags.contains("build") { fileType = .build }
        else if tags.contains("config") { fileType = .config }
        else if tags.contains("docs") { fileType = .docs }
        else if tags.contains("source") { fileType = .source }
        else { fileType = .unknown }

        return FileClassification(fileType: fileType, corpusTier: tier, roleTags: Array(Set(tags)).sorted())
    }
}
