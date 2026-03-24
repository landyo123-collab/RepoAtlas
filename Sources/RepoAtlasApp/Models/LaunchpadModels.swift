import Foundation

enum LaunchpadOutputMode: String, Codable, CaseIterable {
    case webPreview
    case nativeApp
    case terminal

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mode = LaunchpadOutputMode(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported output mode: \(raw)")
        }
        self = mode
    }
}

struct LaunchpadRunPlan: Codable, Equatable {
    let projectType: String
    let command: String
    let args: [String]
    let workingDirectory: String
    let outputMode: LaunchpadOutputMode
    let port: Int?
    let confidence: Double
    let reason: String
    let launchNotes: String?
    let isRunnable: Bool
    let blocker: String?
    let appBundlePath: String?

    var clampedConfidence: Double {
        min(max(confidence, 0), 1)
    }

    var commandDisplay: String {
        ([command] + args).map(Self.quoteIfNeeded).joined(separator: " ")
    }

    var workingDirectoryDisplay: String {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "." : trimmed
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        guard value.contains(" ") || value.contains("\"") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

struct RepoRunContext {
    let prompt: String
    let includedFiles: [String]
}

