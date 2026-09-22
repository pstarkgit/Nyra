import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var runtime: AppRuntime
    @ObservedObject private var model: AppModel
    @ObservedObject private var coordinator: ConversationCoordinator
    @ObservedObject private var synthesizer: PollySpeechSynthesizer

    init(runtime: AppRuntime) {
        self.runtime = runtime
        model = runtime.model
        coordinator = runtime.coordinator
        synthesizer = runtime.synthesizer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            taskPicker
            voiceModelPicker
            connectionRow
            voicePicker
            sessionButton
            if let approval = coordinator.activeApproval {
                ApprovalView(
                    approval: approval,
                    approve: { Task { await model.answerApproval(.approveOnce) } },
                    deny: { Task { await model.answerApproval(.decline) } }
                )
            }
            Divider()
            permissionSection
            Text("Microphone audio stays on this Mac. In Polly mode, only Codex's reply text goes to AWS. Apple On-Device mode sends no speech output to AWS. Right Option interrupts speech or starts/stops a session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh Tasks") {
                    Task { await model.connectAndRefresh() }
                }
                .disabled(model.isRefreshing)
                Spacer()
                Button("Quit") { runtime.quit() }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: coordinator.state.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(coordinator.state.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nyra").font(.headline)
                Text(coordinator.state.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var taskPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CODEX TASK").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Task", selection: Binding(
                get: { model.selectedTaskID ?? "" },
                set: { model.selectTask(id: $0) }
            )) {
                if model.tasks.isEmpty {
                    Text("No tasks found").tag("")
                } else {
                    ForEach(model.tasks) { task in
                        Text(task.title.menuLabel).tag(task.id)
                    }
                }
            }
            .labelsHidden()
            if let task = model.selectedTask {
                Text(task.cwd)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var connectionRow: some View {
        HStack(spacing: 6) {
            Circle().fill(model.connectionStatus.tint).frame(width: 7, height: 7)
            Text(model.connectionStatus.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var voiceModelPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CONVERSATION MODEL")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Conversation model", selection: Binding(
                get: { model.selectedVoiceModelID },
                set: { model.selectVoiceModel(id: $0) }
            )) {
                ForEach(VoiceModelOption.supported) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .labelsHidden()
        }
    }

    private var sessionButton: some View {
        Button {
            Task { await model.toggleSession() }
        } label: {
            Label(
                coordinator.state == .idle ? "Start Voice Session" : "End Voice Session",
                systemImage: coordinator.state == .idle ? "waveform.circle.fill" : "stop.circle.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.selectedTask == nil || model.connectionStatus != .connected)
    }

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("VOICE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Output", selection: Binding(
                get: { synthesizer.provider },
                set: { synthesizer.selectProvider($0) }
            )) {
                ForEach(SpeechOutputProvider.allCases) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                voiceSelectionPicker
                Button("Preview") {
                    Task {
                        await synthesizer.speak(
                            "Hi Patrick. This is Nyra using the selected voice."
                        )
                    }
                }
                if synthesizer.provider == .amazonPolly {
                    Button {
                        Task { await synthesizer.refreshPollyVoices() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(synthesizer.isRefreshingPollyVoices)
                    .help("Refresh AWS Polly voices")
                }
            }

            Label(
                synthesizer.statusLabel,
                systemImage: synthesizer.provider == .appleOnDevice
                    ? "desktopcomputer" : "cloud.fill"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            if synthesizer.isRefreshingPollyVoices {
                ProgressView("Loading Polly voices…")
                    .controlSize(.small)
                    .font(.caption2)
            } else if synthesizer.provider == .amazonPolly,
                      let error = synthesizer.voiceCatalogError {
                Text("Polly catalog unavailable: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var voiceSelectionPicker: some View {
        switch synthesizer.provider {
        case .appleOnDevice:
            Picker("Apple voice", selection: Binding(
                get: { synthesizer.selectedAppleVoiceIdentifier },
                set: { synthesizer.selectAppleVoice($0) }
            )) {
                ForEach(synthesizer.appleVoices) { voice in
                    Text(voice.label).tag(voice.id)
                }
            }
            .labelsHidden()
        case .amazonPolly:
            Picker("Polly voice", selection: Binding(
                get: { synthesizer.selectedPollyVoiceID },
                set: { synthesizer.selectPollyVoice($0) }
            )) {
                ForEach(synthesizer.pollyVoices) { voice in
                    Text(voice.label).tag(voice.id)
                }
            }
            .labelsHidden()
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PERMISSIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                permissionPill("Microphone", granted: AppleSpeechSession.microphonePermission == .authorized)
                permissionPill("Hotkey", granted: GlobalHotkey.hasAccessibility)
            }
            Button("Grant or Refresh Permissions") {
                Task {
                    await model.requestPermissions()
                    runtime.restartHotkey()
                }
            }
            .font(.caption)
        }
    }

    private func permissionPill(_ title: String, granted: Bool) -> some View {
        Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.caption2)
            .foregroundStyle(granted ? .green : .orange)
    }
}

private extension String {
    var menuLabel: String {
        count <= 30 ? self : String(prefix(29)) + "…"
    }
}

private extension AppConnectionStatus {
    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting to Codex…"
        case .connected: return "Connected to Codex"
        case .failed(let message): return "Connection failed: \(message)"
        }
    }

    var tint: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected, .failed: return .red
        }
    }
}

extension ConversationState {
    var displayName: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .transcribing: return "Understanding"
        case .waitingForCodex: return "Codex is working"
        case .awaitingApproval: return "Approval needed"
        case .speaking: return "Speaking"
        case .ending: return "Ending session"
        case .failed(let message): return "Needs attention: \(message)"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .idle: return "waveform.circle"
        case .listening, .transcribing: return "waveform.circle.fill"
        case .waitingForCodex: return "ellipsis.circle.fill"
        case .awaitingApproval: return "exclamationmark.circle.fill"
        case .speaking: return "speaker.wave.2.circle.fill"
        case .ending: return "stop.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .listening, .transcribing: return .green
        case .waitingForCodex, .speaking: return .purple
        case .awaitingApproval: return .orange
        case .ending: return .secondary
        case .failed: return .red
        }
    }
}
