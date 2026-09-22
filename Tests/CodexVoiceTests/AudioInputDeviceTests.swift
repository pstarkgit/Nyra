import CoreAudio
import Foundation
import Testing
@testable import CodexVoice

@Test func deviceEnumerationIsDeduplicatedAndStable() {
    let devices = CoreAudioInputDeviceCatalog.normalized([
        inputDevice(uid: "usb-b", name: "Studio Mic", id: 3),
        inputDevice(uid: "built-in", name: "MacBook Microphone", id: 1),
        inputDevice(uid: "usb-b", name: "Studio Mic Duplicate", id: 9),
        inputDevice(uid: "virtual", name: "Loopback", id: 2),
        inputDevice(uid: " ", name: "Invalid", id: 4),
    ])

    #expect(devices.map(\.uid) == ["virtual", "built-in", "usb-b"])
    #expect(devices.map(\.name) == ["Loopback", "MacBook Microphone", "Studio Mic"])
}

@MainActor
@Test func selectedDevicePersistsAndIsApplied() async throws {
    let builtIn = inputDevice(uid: "built-in", name: "MacBook Microphone", id: 1)
    let studio = inputDevice(uid: "studio", name: "Studio Mic", id: 2)
    let preferences = InputPreferences()
    let applier = RecordingInputApplier()
    let controller = AudioInputDeviceController(
        catalog: TestInputCatalog(devices: [studio, builtIn], defaultDevice: builtIn),
        applier: applier,
        preferences: preferences
    )

    await controller.refresh()
    controller.selectPickerID(studio.uid)
    let resolution = try controller.prepareForCapture()

    #expect(controller.selectedDeviceUID == studio.uid)
    #expect(controller.pickerSelectionID == studio.uid)
    #expect(preferences.values[AppPreferenceKey.selectedInputDeviceUID] == studio.uid)
    #expect(preferences.values[AppPreferenceKey.selectedInputDeviceName] == studio.name)
    #expect(resolution == .init(device: studio, fellBackToSystemDefault: false))
    #expect(applier.appliedDeviceIDs.last == studio.audioObjectID)
    #expect(controller.state == .active(name: studio.name, systemDefault: false))
}

@MainActor
@Test func unavailableSavedDeviceFallsBackWithoutForgettingSelection() async {
    let builtIn = inputDevice(uid: "built-in", name: "MacBook Microphone", id: 1)
    let preferences = InputPreferences(values: [
        AppPreferenceKey.selectedInputDeviceUID: "missing-device",
        AppPreferenceKey.selectedInputDeviceName: "Desk Microphone",
    ])
    let applier = RecordingInputApplier()
    let controller = AudioInputDeviceController(
        catalog: TestInputCatalog(devices: [builtIn], defaultDevice: builtIn),
        applier: applier,
        preferences: preferences
    )

    await controller.refresh()

    #expect(controller.selectedDeviceUID == "missing-device")
    #expect(controller.pickerSelectionID == AudioInputDeviceController.systemDefaultPickerID)
    #expect(applier.appliedDeviceIDs == [builtIn.audioObjectID])
    #expect(controller.state == .missing(
        savedName: "Desk Microphone",
        fallbackName: builtIn.name
    ))
}

@MainActor
@Test func catalogOrApplicationFailureIsVisible() async {
    let preferences = InputPreferences()
    let applier = RecordingInputApplier()
    let controller = AudioInputDeviceController(
        catalog: TestInputCatalog(
            devices: [],
            defaultDevice: nil,
            resolveError: .unavailable
        ),
        applier: applier,
        preferences: preferences
    )

    await controller.refresh()

    #expect(controller.state == .error("Test input catalog unavailable."))
    #expect(applier.appliedDeviceIDs.isEmpty)
}

@MainActor
@Test func systemDefaultSelectionClearsPersistedDevice() async {
    let builtIn = inputDevice(uid: "built-in", name: "MacBook Microphone", id: 1)
    let studio = inputDevice(uid: "studio", name: "Studio Mic", id: 2)
    let preferences = InputPreferences(values: [
        AppPreferenceKey.selectedInputDeviceUID: studio.uid,
        AppPreferenceKey.selectedInputDeviceName: studio.name,
    ])
    let controller = AudioInputDeviceController(
        catalog: TestInputCatalog(devices: [builtIn, studio], defaultDevice: builtIn),
        applier: RecordingInputApplier(),
        preferences: preferences
    )

    await controller.refresh()
    controller.selectPickerID(AudioInputDeviceController.systemDefaultPickerID)

    #expect(controller.selectedDeviceUID == nil)
    #expect(preferences.values[AppPreferenceKey.selectedInputDeviceUID] == nil)
    #expect(preferences.values[AppPreferenceKey.selectedInputDeviceName] == nil)
    #expect(controller.state == .active(name: builtIn.name, systemDefault: true))
}

private func inputDevice(uid: String, name: String, id: AudioDeviceID) -> AudioInputDevice {
    AudioInputDevice(uid: uid, name: name, audioObjectID: id)
}

private struct TestInputCatalog: AudioInputDeviceCataloging {
    let devices: [AudioInputDevice]
    let defaultDevice: AudioInputDevice?
    var resolveError: TestInputCatalogError?

    init(
        devices: [AudioInputDevice],
        defaultDevice: AudioInputDevice?,
        resolveError: TestInputCatalogError? = nil
    ) {
        self.devices = devices
        self.defaultDevice = defaultDevice
        self.resolveError = resolveError
    }

    func availableInputDevices() throws -> [AudioInputDevice] { devices }

    func resolve(preferredUID: String?) throws -> AudioInputDeviceResolution {
        if let resolveError { throw resolveError }
        if let preferredUID,
           let selected = devices.first(where: { $0.uid == preferredUID }) {
            return .init(device: selected, fellBackToSystemDefault: false)
        }
        guard let defaultDevice else { throw TestInputCatalogError.unavailable }
        return .init(
            device: defaultDevice,
            fellBackToSystemDefault: preferredUID != nil
        )
    }
}

@MainActor
private final class RecordingInputApplier: AudioInputDeviceApplying {
    private(set) var appliedDeviceIDs: [AudioDeviceID] = []
    func apply(deviceID: AudioDeviceID) throws { appliedDeviceIDs.append(deviceID) }
}

private final class InputPreferences: PreferenceStoring {
    var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func string(forKey defaultName: String) -> String? { values[defaultName] }

    func set(_ value: Any?, forKey defaultName: String) {
        if let value = value as? String {
            values[defaultName] = value
        } else {
            values.removeValue(forKey: defaultName)
        }
    }
}

private enum TestInputCatalogError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Test input catalog unavailable." }
}
