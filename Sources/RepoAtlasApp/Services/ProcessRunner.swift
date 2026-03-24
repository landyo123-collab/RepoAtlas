import Foundation

final class ProcessRunner {
    private var process: Process?
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    var isRunning: Bool {
        process?.isRunning == true
    }

    func run(
        command: String,
        args: [String],
        workingDirectory: URL,
        environmentOverrides: [String: String] = [:],
        onOutput: @escaping (_ text: String, _ isStdErr: Bool) -> Void,
        onExit: @escaping (_ exitCode: Int32) -> Void
    ) throws {
        stop()

        let task = Process()
        task.currentDirectoryURL = workingDirectory
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        if !environmentOverrides.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environmentOverrides {
                merged[key] = value
            }
            task.environment = merged
        }

        if command.contains("/") {
            task.executableURL = URL(fileURLWithPath: command)
            task.arguments = args
        } else {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = [command] + args
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            DispatchQueue.main.async {
                onOutput(text, false)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            DispatchQueue.main.async {
                onOutput(text, true)
            }
        }

        task.terminationHandler = { [weak self] process in
            self?.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self?.stderrPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                onExit(process.terminationStatus)
            }
        }

        process = task
        try task.run()
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        self.process = nil
    }
}
