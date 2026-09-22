import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let uid: String
    let name: String
    let audioObjectID: AudioDeviceID

    var id: String { uid }
}

struct AudioInputDeviceResolution: Equatable, Sendable {
    let device: AudioInputDevice
    let fellBackToSystemDefault: Bool
}

enum AudioInputDeviceState: Equatable, Sendable {
    case loading
    case active(name: String, systemDefault: Bool)
    case missing(savedName: String, fallbackName: String)
    case error(String)
}

enum AudioInputDeviceError: LocalizedError, Equatable, Sendable {
    case coreAudio(operation: String, status: OSStatus)
    case noInputDevice
    case audioUnitUnavailable
    case deviceChangeWhileCapturing
    case applyFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let operation, let status):
            return "CoreAudio could not \(operation) (status \(status))."
        case .noInputDevice:
            return "No input-capable CoreAudio device is available."
        case .audioUnitUnavailable:
            return "Nyra could not access the microphone audio unit."
        case .deviceChangeWhileCapturing:
            return "Stop the current voice session before changing microphones."
        case .applyFailed(let status):
            return "Nyra could not activate the selected microphone (status \(status))."
        }
    }
}

protocol AudioInputDeviceCataloging: Sendable {
    func availableInputDevices() throws -> [AudioInputDevice]
    func resolve(preferredUID: String?) throws -> AudioInputDeviceResolution
}

struct CoreAudioInputDeviceCatalog: AudioInputDeviceCataloging {
    func availableInputDevices() throws -> [AudioInputDevice] {
        let devices = try allDeviceIDs().compactMap { deviceID in
            try? inputDevice(for: deviceID)
        }
        return Self.normalized(devices)
    }

    func resolve(preferredUID: String?) throws -> AudioInputDeviceResolution {
        if let preferredUID {
            let selectedID = try deviceID(forUID: preferredUID)
            if selectedID != kAudioObjectUnknown,
               let selected = try inputDevice(for: selectedID) {
                return AudioInputDeviceResolution(
                    device: selected,
                    fellBackToSystemDefault: false
                )
            }
        }

        let fallbackID = try defaultInputDeviceID()
        guard fallbackID != kAudioObjectUnknown,
              let fallback = try inputDevice(for: fallbackID) else {
            throw AudioInputDeviceError.noInputDevice
        }
        return AudioInputDeviceResolution(
            device: fallback,
            fellBackToSystemDefault: preferredUID != nil
        )
    }

    static func normalized(_ devices: [AudioInputDevice]) -> [AudioInputDevice] {
        var unique: [String: AudioInputDevice] = [:]
        for device in devices {
            let uid = device.uid.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty,
                  !name.isEmpty,
                  !uid.hasPrefix("CADefaultDeviceAggregate-"),
                  !name.hasPrefix("CADefaultDeviceAggregate-"),
                  unique[uid] == nil else { continue }
            unique[uid] = AudioInputDevice(
                uid: uid,
                name: name,
                audioObjectID: device.audioObjectID
            )
        }
        return unique.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.uid < $1.uid : order == .orderedAscending
        }
    }

    private func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size
            ),
            operation: "list input devices"
        )
        guard size > 0 else { return [] }
        var devices = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        let status = devices.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }
        try check(status, operation: "list input devices")
        return devices
    }

    private func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &deviceID
            ),
            operation: "read the system default input"
        )
        return deviceID
    }

    private func deviceID(forUID uid: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let qualifierSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                pointer,
                &size,
                &deviceID
            )
        }
        try check(status, operation: "resolve the saved input device")
        return deviceID
    }

    private func inputDevice(for deviceID: AudioDeviceID) throws -> AudioInputDevice? {
        guard try inputChannelCount(for: deviceID) > 0 else { return nil }
        return AudioInputDevice(
            uid: try stringProperty(
                kAudioDevicePropertyDeviceUID,
                deviceID: deviceID,
                operation: "read an input device UID"
            ),
            name: try stringProperty(
                kAudioObjectPropertyName,
                deviceID: deviceID,
                operation: "read an input device name"
            ),
            audioObjectID: deviceID
        )
    }

    private func inputChannelCount(for deviceID: AudioDeviceID) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
            operation: "inspect an input device"
        )
        guard size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage),
            operation: "inspect an input device"
        )
        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    private func stringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        operation: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value),
            operation: operation
        )
        guard let value else {
            throw AudioInputDeviceError.coreAudio(operation: operation, status: -1)
        }
        return value.takeUnretainedValue() as String
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioInputDeviceError.coreAudio(operation: operation, status: status)
        }
    }
}

@MainActor
protocol AudioInputDeviceApplying: AnyObject {
    func apply(deviceID: AudioDeviceID) throws
}

@MainActor
final class CoreAudioInputDeviceApplier: AudioInputDeviceApplying {
    private let audioEngine: AVAudioEngine

    init(audioEngine: AVAudioEngine) {
        self.audioEngine = audioEngine
    }

    func apply(deviceID: AudioDeviceID) throws {
        guard !audioEngine.isRunning else {
            throw AudioInputDeviceError.deviceChangeWhileCapturing
        }
        guard let audioUnit = audioEngine.inputNode.audioUnit else {
            throw AudioInputDeviceError.audioUnitUnavailable
        }
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioInputDeviceError.applyFailed(status)
        }
    }
}

@MainActor
protocol AudioInputDeviceControlling: AnyObject {
    @discardableResult
    func prepareForCapture() throws -> AudioInputDeviceResolution
}

@MainActor
final class AudioInputDeviceController: ObservableObject, AudioInputDeviceControlling {
    static let systemDefaultPickerID = "__system_default_input__"

    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var selectedDeviceUID: String?
    @Published private(set) var state: AudioInputDeviceState = .loading
    @Published private(set) var isRefreshing = false

    private let catalog: AudioInputDeviceCataloging
    private let applier: AudioInputDeviceApplying
    private let preferences: PreferenceStoring
    private var savedDeviceName: String?

    var pickerSelectionID: String {
        guard let selectedDeviceUID,
              devices.contains(where: { $0.uid == selectedDeviceUID }) else {
            return Self.systemDefaultPickerID
        }
        return selectedDeviceUID
    }

    convenience init(
        audioEngine: AVAudioEngine,
        preferences: PreferenceStoring = UserDefaults.standard
    ) {
        self.init(
            catalog: CoreAudioInputDeviceCatalog(),
            applier: CoreAudioInputDeviceApplier(audioEngine: audioEngine),
            preferences: preferences
        )
    }

    init(
        catalog: AudioInputDeviceCataloging,
        applier: AudioInputDeviceApplying,
        preferences: PreferenceStoring
    ) {
        self.catalog = catalog
        self.applier = applier
        self.preferences = preferences
        selectedDeviceUID = preferences.string(
            forKey: AppPreferenceKey.selectedInputDeviceUID
        )
        savedDeviceName = preferences.string(
            forKey: AppPreferenceKey.selectedInputDeviceName
        )
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        state = .loading
        defer { isRefreshing = false }
        let catalog = self.catalog
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try catalog.availableInputDevices()
            }.value
            devices = CoreAudioInputDeviceCatalog.normalized(loaded)
            _ = try activateSelection()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func selectPickerID(_ id: String) {
        if id == Self.systemDefaultPickerID {
            selectedDeviceUID = nil
            savedDeviceName = nil
            preferences.set(nil, forKey: AppPreferenceKey.selectedInputDeviceUID)
            preferences.set(nil, forKey: AppPreferenceKey.selectedInputDeviceName)
        } else {
            guard let device = devices.first(where: { $0.uid == id }) else {
                state = .error("The selected microphone is no longer available.")
                return
            }
            selectedDeviceUID = device.uid
            savedDeviceName = device.name
            preferences.set(device.uid, forKey: AppPreferenceKey.selectedInputDeviceUID)
            preferences.set(device.name, forKey: AppPreferenceKey.selectedInputDeviceName)
        }
        do {
            _ = try activateSelection()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    @discardableResult
    func prepareForCapture() throws -> AudioInputDeviceResolution {
        do {
            return try activateSelection()
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    private func activateSelection() throws -> AudioInputDeviceResolution {
        let resolution = try catalog.resolve(preferredUID: selectedDeviceUID)
        try applier.apply(deviceID: resolution.device.audioObjectID)
        if resolution.fellBackToSystemDefault, selectedDeviceUID != nil {
            state = .missing(
                savedName: savedDeviceName ?? "Saved microphone",
                fallbackName: resolution.device.name
            )
        } else {
            if selectedDeviceUID != nil {
                savedDeviceName = resolution.device.name
                preferences.set(
                    resolution.device.name,
                    forKey: AppPreferenceKey.selectedInputDeviceName
                )
            }
            state = .active(
                name: resolution.device.name,
                systemDefault: selectedDeviceUID == nil
            )
        }
        return resolution
    }
}
