import AudioToolbox
import CoreAudio
import Foundation

protocol AudioDucking: AnyObject {
    func snapshotBeforeCapture()
    func duck()
    func restore()
}

final class NoopAudioDucker: AudioDucking {
    func snapshotBeforeCapture() {}
    func duck() {}
    func restore() {}
}

struct AudioOutputAccess {
    let defaultDevice: () -> AudioObjectID
    let readVolume: (AudioObjectID) -> Float?
    let writeVolume: (AudioObjectID, Float) -> Bool

    static let system = AudioOutputAccess(
        defaultDevice: {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var device = AudioObjectID(0)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &device
            )
            return status == noErr ? device : 0
        },
        readVolume: { device in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var volume = Float32.zero
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(
                device, &address, 0, nil, &size, &volume
            )
            return status == noErr ? volume : nil
        },
        writeVolume: { device, value in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var volume = Float32(max(0, min(1, value)))
            let size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectSetPropertyData(
                device, &address, 0, nil, size, &volume
            ) == noErr
        }
    )
}

final class AudioDucker: AudioDucking {
    private let access: AudioOutputAccess
    private let duckVolume: Float
    private var device: AudioObjectID?
    private var originalVolume: Float?
    private var appliedVolume: Float?

    init(
        access: AudioOutputAccess = .system,
        duckVolume: Float = 0.20
    ) {
        self.access = access
        self.duckVolume = max(0, min(1, duckVolume))
    }

    func snapshotBeforeCapture() {
        let device = access.defaultDevice()
        guard device != 0, let volume = access.readVolume(device) else {
            self.device = nil
            originalVolume = nil
            appliedVolume = nil
            return
        }
        self.device = device
        originalVolume = volume
        appliedVolume = nil
    }

    func duck() {
        guard let device, let originalVolume,
              let current = access.readVolume(device) else { return }
        let target = min(originalVolume, duckVolume)
        guard current > target + 0.005 else {
            appliedVolume = current
            return
        }
        if access.writeVolume(device, target) {
            appliedVolume = target
        }
    }

    func restore() {
        defer {
            device = nil
            originalVolume = nil
            appliedVolume = nil
        }
        guard let device, let originalVolume, let appliedVolume,
              let current = access.readVolume(device),
              abs(current - appliedVolume) < 0.015 else { return }
        _ = access.writeVolume(device, originalVolume)
    }
}
