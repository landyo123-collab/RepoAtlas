import SwiftUI
import WebKit

struct LaunchpadView: View {
    @EnvironmentObject private var store: RepoStore
    let configuration: DeepSeekConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Launchpad")
                    .font(.title3.bold())
                Spacer()
                if let plan = store.launchpadPlan {
                    Text(plan.outputMode.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
            }

            Text("Detect a local run plan first, optionally refine with DeepSeek, then approve execution.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Figure Out & Run") {
                    store.figureOutLaunchpadPlan(configuration: configuration)
                }
                .disabled(store.repo == nil || store.isPlanningLaunchpad || store.isRunningLaunchpad)

                if store.isPlanningLaunchpad {
                    ProgressView("Planning...")
                        .controlSize(.small)
                }
            }

            if let error = store.launchpadPlanningError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let notice = store.launchpadPlanningNotice, !notice.isEmpty {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let raw = store.launchpadPlannerRawResponse, !raw.isEmpty {
                DisclosureGroup("Planner Debug Details") {
                    Text(raw)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let plan = store.launchpadPlan {
                GroupBox("Run Plan (approval required)") {
                    VStack(alignment: .leading, spacing: 8) {
                        planRow("Detected Type", value: plan.projectType)
                        planRow("Command", value: plan.commandDisplay)
                        planRow("Working Directory", value: plan.workingDirectoryDisplay)
                        planRow("Output Mode", value: plan.outputMode.rawValue)
                        if let port = plan.port {
                            planRow("Likely Port", value: "\(port)")
                        }
                        planRow("Confidence", value: String(format: "%.0f%%", plan.clampedConfidence * 100))
                        planRow("Runnable", value: plan.isRunnable ? "Yes" : "No")
                        if let blocker = plan.blocker, !blocker.isEmpty {
                            planRow("Blocker", value: blocker)
                        }
                        planRow("Reason", value: plan.reason)
                        if let notes = plan.launchNotes, !notes.isEmpty {
                            planRow("Notes", value: notes)
                        }
                        if let appPath = plan.appBundlePath, !appPath.isEmpty {
                            planRow("App Bundle Path", value: appPath)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                    Button("Run") {
                        store.runApprovedLaunchpadPlan()
                    }
                    .disabled(!plan.isRunnable || store.isRunningLaunchpad)

                    Button("Rerun") {
                        store.rerunLaunchpadPlan()
                    }
                    .disabled(!plan.isRunnable || store.isRunningLaunchpad)

                    Button("Stop") {
                        store.stopLaunchpadRun()
                    }
                    .disabled(!store.isRunningLaunchpad)
                }
            }

            if let runError = store.launchpadRunError, !runError.isEmpty {
                Text(runError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let failureMessage = store.launchpadFailureClassificationMessage, !failureMessage.isEmpty {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let execution = store.launchpadExecutionCommandDisplay, !execution.isEmpty {
                GroupBox("Execution") {
                    VStack(alignment: .leading, spacing: 6) {
                        planRow("Execution Command", value: execution)
                        if let resolvedExecutable = store.launchpadResolvedExecutableMessage, !resolvedExecutable.isEmpty {
                            Text(resolvedExecutable)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let envOverride = store.launchpadEnvironmentMessage, !envOverride.isEmpty {
                            Text(envOverride)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if store.launchpadSetupRequired {
                GroupBox("Environment Setup Required") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let reason = store.launchpadBootstrapReason, !reason.isEmpty {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !store.launchpadBootstrapCommands.isEmpty {
                            Text(store.launchpadBootstrapCommands.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button(store.isBootstrappingPythonEnvironment ? "Setting Up..." : "Set Up Python Environment") {
                            store.setUpPythonEnvironment()
                        }
                        .disabled(
                            store.isBootstrappingPythonEnvironment
                            || store.isRunningLaunchpad
                            || store.launchpadBootstrapCommands.isEmpty
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            outputPane
        }
    }

    @ViewBuilder
    private var outputPane: some View {
        if let plan = store.launchpadPlan {
            switch plan.outputMode {
            case .webPreview:
                GroupBox("localhost UI Preview") {
                    if let url = store.launchpadLivePreviewURL {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(url.absoluteString)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                                Button("Open in Browser") {
                                    store.openLaunchpadPreviewInBrowser()
                                }
                                .buttonStyle(.borderless)
                            }
                            LocalhostPreviewView(url: url)
                                .frame(minHeight: 260)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            if let plannedURL = store.launchpadPlannedPreviewURL {
                                Text("Planned preview URL: \(plannedURL.absoluteString)")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            } else {
                                Text("Planned preview URL not available yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text(store.launchpadWebStartupStatus ?? "Starting dev server...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                logsPane
            case .nativeApp:
                GroupBox("Native App Status") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let strategy = store.launchpadNativeStrategy, !strategy.isEmpty {
                            planRow("Strategy", value: strategy)
                        }
                        if let buildCommand = store.launchpadNativeBuildCommandDisplay, !buildCommand.isEmpty {
                            planRow("Build Command", value: buildCommand)
                        }
                        if let status = store.launchpadNativeStatus, !status.isEmpty {
                            planRow("Status", value: status)
                        } else if store.isRunningLaunchpad {
                            Text("Detecting native target...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let targetPath = store.launchpadNativeLaunchTargetPath, !targetPath.isEmpty {
                            Text("Launch target: \(targetPath)")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }

                        HStack(spacing: 10) {
                            Button("Show Build Logs") {
                                store.setLaunchpadTerminalOutputExpanded(true)
                            }
                            .buttonStyle(.borderless)

                            Button("Open Full App") {
                                store.openLaunchpadNativeTarget()
                            }
                            .buttonStyle(.borderless)
                            .disabled(!store.launchpadNativeIsGUIApp || store.launchpadNativeLaunchTargetPath == nil)

                            Button("Focus App") {
                                store.focusLaunchedNativeApp()
                            }
                            .buttonStyle(.borderless)
                            .disabled(!store.launchpadNativeIsGUIApp || store.launchpadLaunchedAppPath == nil)

                            Button("Relaunch") {
                                store.relaunchLaunchpadNativeTarget()
                            }
                            .buttonStyle(.borderless)
                            .disabled(!store.launchpadNativeIsGUIApp || store.launchpadNativeLaunchTargetPath == nil)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                logsPane
            case .terminal:
                logsPane
            }
        } else if !store.launchpadContextFiles.isEmpty {
            GroupBox("Context Sent To Planner") {
                Text(store.launchpadContextFiles.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var logsPane: some View {
        GroupBox {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { store.launchpadTerminalOutputExpanded },
                    set: { store.setLaunchpadTerminalOutputExpanded($0) }
                )
            ) {
                if store.launchpadLogs.isEmpty {
                    Text("No process output yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        Text(store.launchpadLogs.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 4)
                    }
                    .frame(minHeight: 180)
                }
            } label: {
                Text(terminalOutputSummary)
                    .font(.caption.weight(.semibold))
            }

            if let exitCode = store.launchpadExitCode {
                Text("Exit code: \(exitCode)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var terminalOutputSummary: String {
        let count = store.launchpadLogLineCount
        let lineWord = count == 1 ? "line" : "lines"
        if store.isRunningLaunchpad {
            return "Terminal Output • Running… • \(count) \(lineWord)"
        }
        return "Terminal Output (\(count) \(lineWord))"
    }

    private func planRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}

private struct LocalhostPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard nsView.url != url else { return }
        nsView.load(URLRequest(url: url))
    }
}
