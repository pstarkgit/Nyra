import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var runtime: AppRuntime
    @ObservedObject private var model: AppModel
    @ObservedObject private var coordinator: ConversationCoordinator
    @ObservedObject private var nova: NovaConversationController
    @ObservedObject private var synthesizer: PollySpeechSynthesizer
    @ObservedObject private var inputDevices: AudioInputDeviceController

    init(runtime: AppRuntime) {
        self.runtime = runtime
        model = runtime.model
        coordinator = runtime.coordinator
        nova = runtime.nova
        synthesizer = runtime.synthesizer
        inputDevices = runtime.inputDevices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            enginePicker
            inputDevicePicker
            if model.selectedConversationEngine == .naturalRealtime {
                novaVoicePicker
                novaStatus
                novaTranscript
            } else {
                taskPicker
                voiceModelPicker
                connectionRow
                legacyVoicePicker
                if let approval = coordinator.activeApproval {
                    ApprovalView(
                        approval: approval,
                        approve: { Task { await model.answerApproval(.approveOnce) } },
                        deny: { Task { await model.answerApproval(.decline) } }
                    )
                }
            }
            sessionButton
            Divider()
            permissionSection
            privacyNotice
            HStack {
                if model.selectedConversationEngine == .codexAgent {
                    Button("Refresh Tasks") {
                        Task { await model.connectAndRefresh() }
                    }
                    .disabled(model.isRefreshing)
                }
                Spacer()
                Button("Quit") { runtime.quit() }
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    private var header: some View {
        let natural = model.selectedConversationEngine == .naturalRealtime
        let symbol = natural ? nova.state.menuBarSymbol : coordinator.state.menuBarSymbol
        let tint = natural ? nova.state.tint : coordinator.state.tint
        let status = natural ? nova.state.displayName : coordinator.state.displayName
        return HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nyra").font(.headline)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CONVERSATION ENGINE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Conversation engine", selection: Binding(
                get: { model.selectedConversationEngine },
                set: { model.selectConversationEngine($0) }
            )) {
                ForEach(ConversationEngineOption.allCases) { engine in
                    Text(engine.label).tag(engine)
                }
            }
            .labelsHidden()
            .disabled(model.isSessionActive)
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

    private var inputDevicePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("MICROPHONE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                Picker("Microphone", selection: Binding(
                    get: { inputDevices.pickerSelectionID },
                    set: { inputDevices.selectPickerID($0) }
                )) {
                    Text("System Default")
                        .tag(AudioInputDeviceController.systemDefaultPickerID)
                    ForEach(inputDevices.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                Button {
                    Task { await inputDevices.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(inputDevices.isRefreshing || model.isSessionActive)
                .help("Refresh microphones")
            }
            .disabled(model.isSessionActive)
            inputDeviceStatus
        }
    }

    @ViewBuilder
    private var inputDeviceStatus: some View {
        switch inputDevices.state {
        case .loading:
            ProgressView("Loading microphones…")
                .controlSize(.small)
                .font(.caption2)
        case .active(let name, let systemDefault):
            Label(
                systemDefault ? "Active: \(name) · System Default" : "Active: \(name)",
                systemImage: "mic.fill"
            )
            .font(.caption2)
            .foregroundStyle(.green)
        case .missing(let savedName, let fallbackName):
            Label(
                "\(savedName) unavailable · Using \(fallbackName)",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption2)
            .foregroundStyle(.orange)
            .lineLimit(2)
        case .error(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
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

    private var novaVoicePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("SONIC VOICE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Sonic voice", selection: Binding(
                get: { model.selectedNovaVoiceID },
                set: { model.selectNovaVoice(id: $0) }
            )) {
                ForEach(NovaSonicVoice.supported) { voice in
                    Text(voice.label).tag(voice.id)
                }
            }
            .labelsHidden()
            .disabled(nova.state.isActive)
        }
    }

    @ViewBuilder
    private var novaStatus: some View {
        if let error = nova.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if nova.state.isActive {
            Label(
                nova.voiceProcessingEnabled
                    ? "macOS Voice Processing active · AEC, noise suppression, AGC"
                    : "Enabling macOS Voice Processing…",
                systemImage: nova.voiceProcessingEnabled
                    ? "checkmark.shield.fill" : "shield.lefthalf.filled"
            )
            .font(.caption2)
            .foregroundStyle(nova.voiceProcessingEnabled ? .green : .secondary)
        } else {
            Label(
                "Full duplex uses macOS Voice Processing for echo control",
                systemImage: "shield.lefthalf.filled"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var novaTranscript: some View {
        if !nova.transcript.isEmpty
            || !nova.currentUserTranscript.isEmpty
            || !nova.currentAssistantTranscript.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("LIVE TRANSCRIPT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(nova.transcript) { entry in
                            transcriptRow(role: entry.role, text: entry.text)
                        }
                        if !nova.currentUserTranscript.isEmpty,
                           nova.transcript.last?.text != nova.currentUserTranscript {
                            transcriptRow(
                                role: .user,
                                text: nova.currentUserTranscript
                            )
                        }
                        if !nova.currentAssistantTranscript.isEmpty,
                           nova.transcript.last?.text != nova.currentAssistantTranscript {
                            transcriptRow(
                                role: .assistant,
                                text: nova.currentAssistantTranscript
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
        }
    }

    private func transcriptRow(
        role: NovaTranscriptRole,
        text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(role == .user ? "YOU" : "NYRA")
                .font(.caption2.weight(.bold))
                .foregroundStyle(role == .user ? Color.secondary : Color.purple)
            Text(text)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sessionButton: some View {
        let natural = model.selectedConversationEngine == .naturalRealtime
        let active = natural ? nova.state.isActive : coordinator.state != .idle
        let startLabel = natural ? "Start Natural Conversation" : "Start Legacy Codex Session"
        return Button {
            Task { await model.toggleSession() }
        } label: {
            Label(
                active ? "End Conversation" : startLabel,
                systemImage: active ? "stop.circle.fill" : "waveform.circle.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!natural && (
            model.selectedTask == nil || model.connectionStatus != .connected
        ))
    }

    private var legacyVoicePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("LEGACY OUTPUT VOICE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
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

    private var privacyNotice: some View {
        Text(model.selectedConversationEngine == .naturalRealtime
            ? "Natural mode continuously sends microphone audio to Nova 2 Sonic in AWS while the session is open. Audio is memory-only in Nyra. macOS Voice Processing provides echo control, but physical speaker/microphone acceptance is still required. Right Option clears speech or ends the session."
            : "Legacy mode keeps microphone recognition on this Mac, sends finalized text to the selected Codex task, and speaks through Apple or Polly. It is task-aware but slower and half-duplex.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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

extension NovaConversationState {
    var displayName: String {
        switch self {
        case .idle: return "Ready for natural conversation"
        case .connecting: return "Connecting to Nova 2 Sonic"
        case .listening: return "Listening · full duplex"
        case .userSpeaking: return "Listening to you"
        case .responding: return "Nova is responding"
        case .speaking: return "Speaking · interrupt anytime"
        case .ending: return "Ending natural session"
        case .failed(let message): return "Needs attention: \(message)"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .idle: return "waveform.circle"
        case .connecting, .responding: return "ellipsis.circle.fill"
        case .listening, .userSpeaking: return "waveform.circle.fill"
        case .speaking: return "waveform.and.person.filled"
        case .ending: return "stop.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle, .ending: return .secondary
        case .connecting, .responding: return .purple
        case .listening, .userSpeaking: return .green
        case .speaking: return .blue
        case .failed: return .red
        }
    }
}