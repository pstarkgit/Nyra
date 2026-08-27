import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var runtime: AppRuntime
    @ObservedObject private var model: AppModel
    @ObservedObject private var coordinator: ConversationCoordinator

    init(runtime: AppRuntime) {
        self.runtime = runtime
        model = runtime.model
        coordinator = runtime.coordinator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            taskPicker
            connectionRow
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
            Text("Conversation uses local speech recognition and half-duplex playback. Right Option interrupts speech or starts/stops a session.")
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
                Text("Codex Voice").font(.headline)
                Text(coordinator.state.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var taskPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CODEx TASK").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
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

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PERMISSIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                permissionPill("Speech", granted: AppleSpeechSession.speechPermission == .authorized)
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
