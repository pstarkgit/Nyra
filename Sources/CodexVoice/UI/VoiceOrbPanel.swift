import AppKit
import Combine
import SwiftUI

@MainActor
final class VoiceOrbPanelController: ObservableObject {
    weak var model: AppModel?
    private let coordinator: ConversationCoordinator
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(coordinator: ConversationCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard panel == nil, let model else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: VoiceOrbView(
            coordinator: coordinator,
            model: model
        ))
        self.panel = panel

        coordinator.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.updateVisibility(for: state) }
            .store(in: &cancellables)
    }

    private func updateVisibility(for state: ConversationState) {
        guard let panel else { return }
        if state == .idle {
            panel.orderOut(nil)
            return
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.maxY - panel.frame.height - 18
            ))
        }
        panel.orderFrontRegardless()
    }
}

private struct VoiceOrbView: View {
    @ObservedObject var coordinator: ConversationCoordinator
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(coordinator.state.tint.opacity(0.18))
                    Image(systemName: coordinator.state.menuBarSymbol)
                        .foregroundStyle(coordinator.state.tint)
                        .font(.title2)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.state.displayName).font(.headline)
                    Text(secondaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            if let approval = coordinator.activeApproval {
                ApprovalView(
                    approval: approval,
                    approve: { Task { await model.answerApproval(.approveOnce) } },
                    deny: { Task { await model.answerApproval(.decline) } }
                )
            }
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(coordinator.state.tint.opacity(0.30), lineWidth: 1)
        }
    }

    private var secondaryText: String {
        if !coordinator.partialTranscript.isEmpty {
            return coordinator.partialTranscript
        }
        if !coordinator.latestResponse.isEmpty {
            return coordinator.latestResponse
        }
        return coordinator.selectedTask?.title ?? "Select a Codex task"
    }
}
