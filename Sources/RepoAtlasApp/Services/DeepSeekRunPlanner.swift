import Foundation

struct DeepSeekRunPlanner {
    struct PlannerResult {
        let plan: LaunchpadRunPlan
        let rawResponse: String
    }

    enum PlannerError: LocalizedError {
        case invalidJSON(rawResponse: String)
        case decodeFailure(message: String, rawResponse: String)
        case invalidPlan(message: String, rawResponse: String)

        var rawResponse: String {
            switch self {
            case let .invalidJSON(rawResponse):
                return rawResponse
            case let .decodeFailure(_, rawResponse):
                return rawResponse
            case let .invalidPlan(_, rawResponse):
                return rawResponse
            }
        }

        var isParseFailure: Bool {
            switch self {
            case .invalidJSON, .decodeFailure:
                return true
            case .invalidPlan:
                return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return "DeepSeek returned a run plan that was not valid JSON."
            case let .decodeFailure(message, _):
                return "DeepSeek run plan JSON could not be parsed: \(message)"
            case let .invalidPlan(message, _):
                return "DeepSeek run plan is invalid: \(message)"
            }
        }
    }

    private let aiService = DeepSeekService()

    func planRun(context: RepoRunContext, configuration: DeepSeekConfiguration) async throws -> PlannerResult {
        let response = try await aiService.ask(prompt: context.prompt, configuration: configuration)
        let plan = try parsePlan(from: response)
        return PlannerResult(plan: plan, rawResponse: response)
    }

    private func parsePlan(from rawResponse: String) throws -> LaunchpadRunPlan {
        guard let json = extractJSONObject(from: rawResponse) else {
            throw PlannerError.invalidJSON(rawResponse: rawResponse)
        }

        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any] else {
            throw PlannerError.invalidJSON(rawResponse: rawResponse)
        }

        let projectType = requiredString(for: "projectType", in: dictionary)
        let command = requiredString(for: "command", in: dictionary)
        let args = parseArgs(dictionary["args"])
        let workingDirectory = stringValue(dictionary["workingDirectory"]) ?? "."
        let outputMode = try parseOutputMode(dictionary["outputMode"], rawResponse: rawResponse)
        let port = parsePort(dictionary["port"])
        let confidence = try parseConfidence(dictionary["confidence"], rawResponse: rawResponse)
        let reason = requiredString(for: "reason", in: dictionary)
        let launchNotes = optionalString(dictionary["launchNotes"])
        let isRunnable = parseBool(dictionary["isRunnable"]) ?? true
        let blocker = optionalString(dictionary["blocker"])
        let appBundlePath = optionalString(dictionary["appBundlePath"])

        let plan = LaunchpadRunPlan(
            projectType: projectType,
            command: command,
            args: args,
            workingDirectory: workingDirectory,
            outputMode: outputMode,
            port: port,
            confidence: confidence,
            reason: reason,
            launchNotes: launchNotes,
            isRunnable: isRunnable,
            blocker: blocker,
            appBundlePath: appBundlePath
        )
        return try validate(plan: plan, rawResponse: rawResponse)
    }

    private func validate(plan: LaunchpadRunPlan, rawResponse: String) throws -> LaunchpadRunPlan {
        let command = plan.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty || !plan.isRunnable else {
            throw PlannerError.invalidPlan(message: "Runnable plans must include a command.", rawResponse: rawResponse)
        }
        if let port = plan.port, !(1...65535).contains(port) {
            throw PlannerError.invalidPlan(message: "Port must be in 1...65535 when provided.", rawResponse: rawResponse)
        }
        return plan
    }

    private func requiredString(for key: String, in dictionary: [String: Any]) -> String {
        if let value = stringValue(dictionary[key]), !value.isEmpty {
            return value
        }
        return key == "command" ? "" : "unknown"
    }

    private func parseArgs(_ value: Any?) -> [String] {
        if let args = value as? [String] {
            return args
        }
        if let list = value as? [Any] {
            return list.compactMap { stringValue($0) }
        }
        if let single = stringValue(value), !single.isEmpty {
            return [single]
        }
        return []
    }

    private func parseOutputMode(_ value: Any?, rawResponse: String) throws -> LaunchpadOutputMode {
        guard let raw = stringValue(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "") else {
            throw PlannerError.decodeFailure(message: "Missing outputMode.", rawResponse: rawResponse)
        }

        switch raw {
        case "webpreview", "web", "localhost":
            return .webPreview
        case "nativeapp", "native", "swift":
            return .nativeApp
        case "terminal", "cli":
            return .terminal
        default:
            throw PlannerError.decodeFailure(message: "Unsupported outputMode '\(raw)'.", rawResponse: rawResponse)
        }
    }

    private func parsePort(_ value: Any?) -> Int? {
        if value is NSNull || value == nil {
            return nil
        }
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = stringValue(value), let intValue = Int(text) {
            return intValue
        }
        return nil
    }

    private func parseConfidence(_ value: Any?, rawResponse: String) throws -> Double {
        if let number = value as? Double {
            return normalizeConfidence(number)
        }
        if let number = value as? NSNumber {
            return normalizeConfidence(number.doubleValue)
        }
        if let text = stringValue(value) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")
            if let parsed = Double(trimmed) {
                return normalizeConfidence(parsed)
            }
        }
        throw PlannerError.decodeFailure(message: "Missing or invalid confidence.", rawResponse: rawResponse)
    }

    private func normalizeConfidence(_ value: Double) -> Double {
        if value > 1, value <= 100 {
            return value / 100
        }
        return value
    }

    private func optionalString(_ value: Any?) -> String? {
        guard let text = stringValue(value), !text.isEmpty else { return nil }
        return text
    }

    private func parseBool(_ value: Any?) -> Bool? {
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = stringValue(value)?.lowercased() {
            switch text {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if value is NSNull || value == nil {
            return nil
        }
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func extractJSONObject(from text: String) -> String? {
        let cleaned = text.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let start = cleaned.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false

        for idx in cleaned.indices[start...] {
            let ch = cleaned[idx]
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if ch == "\"" {
                inString.toggle()
                continue
            }
            if inString {
                continue
            }
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(cleaned[start...idx])
                }
            }
        }

        return nil
    }
}
