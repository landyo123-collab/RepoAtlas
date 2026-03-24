import Foundation

enum AppConstants {
    static let maxFileSizeBytes = 900_000
    static let previewLineLimit = 500
    static let snippetLineLimit = 80
    static let aiFirstPassLineLimit = 80
    static let aiTailPassLineLimit = 40
    static let aiMaxEstimatedTokens = 7_000
    static let aiReservedMustIncludeTokens = 1_500

    // Retrieval budget (used by repo memory system)
    static let retrievalMaxFiles = 80
    static let retrievalMaxSegments = 150
    static let retrievalMaxTokens = 48_000
    static let retrievalMaxExpansionHops = 2
    static let retrievalMaxNeighborsPerHop = 12

    static let allowedExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cpp", "cc",
        "py", "js", "jsx", "ts", "tsx", "json", "yaml", "yml",
        "md", "txt", "toml", "ini", "cfg", "conf", "java", "kt",
        "kts", "rb", "go", "rs", "php", "html", "css", "scss",
        "sql", "sh", "zsh", "bash", "env", "plist", "xml"
    ]

    static let specialFilenames: Set<String> = [
        "README", "README.md", "Package.swift", "package.json", "Podfile",
        "Cartfile", "Dockerfile", "docker-compose.yml", "Makefile",
        "Gemfile", "Cargo.toml", "build.gradle", "build.gradle.kts",
        "tsconfig.json", "Info.plist", ".env", ".env.example"
    ]

    static let ignoredDirectories: Set<String> = [
        ".git", ".build", ".idea", ".vscode", "node_modules", "Pods",
        "DerivedData", "build", "dist", "coverage", ".next", ".nuxt"
    ]

    static let filenameWeights: [String: Double] = [
        "README": 4.5,
        "Package.swift": 4.5,
        "package.json": 4.5,
        "Podfile": 4.2,
        "Dockerfile": 3.8,
        "docker-compose.yml": 3.8,
        "Makefile": 3.4,
        "Gemfile": 3.2,
        "Cargo.toml": 3.2,
        "Info.plist": 2.4,
        "main": 2.6,
        "app": 2.2,
        "index": 2.0,
        "router": 1.8,
        "service": 1.6,
        "store": 1.6,
        "viewmodel": 1.5,
        "model": 1.2,
        "config": 2.0,
        "test": 1.0
    ]

    static let mustIncludeNames: Set<String> = [
        "README.md", "Package.swift", "package.json", "Podfile", "Cartfile",
        "Dockerfile", "docker-compose.yml", "Makefile", "Cargo.toml",
        "build.gradle", "build.gradle.kts", "tsconfig.json", "Info.plist"
    ]
}
