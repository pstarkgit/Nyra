import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class AppRuntime: ObservableObject {
    let codex: CodexAppServerClient
    let inputDevices: AudioInputDeviceController
    let capture: AppleSpeechSession
    let synthesizer: PollySpeechSynthesizer
    let coordinator: ConversationCoordinator
    let model: AppModel
    let hotkey: GlobalHotkey
    let orb: VoiceOrbPanelController
    private var started = false

    init() {
        let binary = (try? CodexBinaryLocator().resolve())
            ?? URL(filePath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        let audioEngine = AVAudioEngine()
        codex = CodexAppServerClient(executableURL: binary)
        inputDevices = AudioInputDeviceController(audioEngine: audioEngine)
        capture = AppleSpeechSession(
            audioEngine: audioEngine,
            inputDevices: inputDevices
        )
        let localFallback = SystemSpeechSynthesizer(
            selectedVoiceIdentifier: UserDefaults.standard.string(
                forKey: AppPreferenceKey.selectedVoiceIdentifier
            )
        )
        synthesizer = PollySpeechSynthesizer(fallback: localFallback)
        coordinator = ConversationCoordinator(
            codex: codex,
            capture: capture,
            synthesizer: synthesizer
        )
        model = AppModel(codex: codex, coordinator: coordinator)
        hotkey = GlobalHotkey()
        orb = VoiceOrbPanelController(coordinator: coordinator)
        orb.model = model
        Task { @MainActor [weak self] in self?.start() }
    }

    func start() {
        guard !started else { return }
        started = true
        hotkey.onToggle = { [weak model] in
            Task { @MainActor in await model?.handleHotkey() }
        }
        _ = hotkey.start()
        orb.start()
        Task {
            async let tasks: Void = model.connectAndRefresh()
            async let voices: Void = synthesizer.refreshPollyVoices()
            async let inputs: Void = inputDevices.refresh()
            _ = await (tasks, voices, inputs)
        }
    }

    func restartHotkey() {
        _ = hotkey.start()
    }

    func quit() {
        Task { @MainActor [coordinator] in
            await coordinator.shutdown()
            NSApp.terminate(nil)
        }
    }
}

final class NyraAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct NyraApp: App {
    @NSApplicationDelegateAdaptor(NyraAppDelegate.self) private var appDelegate
    @StateObject private var runtime = AppRuntime()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(runtime: runtime)
        } label: {
            VoiceStatusIcon(coordinator: runtime.coordinator)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct VoiceStatusIcon: View {
    @ObservedObject var coordinator: ConversationCoordinator

    var body: some View {
        Image(systemName: coordinator.state.menuBarSymbol)
            .accessibilityLabel("Nyra: \(coordinator.state.displayName)")
    }
}
