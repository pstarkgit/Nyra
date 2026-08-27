import Testing
@testable import CodexVoice

@Test func snapshotsBeforeReadingAgainOrWritingDuckVolume() {
    let recorder = AudioAccessRecorder(initialVolume: 0.8)
    let ducker = AudioDucker(access: recorder.access, duckVolume: 0.2)

    ducker.snapshotBeforeCapture()
    ducker.duck()

    #expect(recorder.operations == [
        "defaultDevice",
        "read:7",
        "read:7",
        "write:7:0.2",
    ])
}

@Test func restoresOriginalVolumeWhenUserDidNotChangeIt() {
    let recorder = AudioAccessRecorder(initialVolume: 0.8)
    let ducker = AudioDucker(access: recorder.access, duckVolume: 0.2)
    ducker.snapshotBeforeCapture()
    ducker.duck()
    recorder.operations.removeAll()

    ducker.restore()

    #expect(recorder.operations == ["read:7", "write:7:0.8"])
    #expect(recorder.volume == 0.8)
}

@Test func doesNotOverwriteUserVolumeChangeDuringDuck() {
    let recorder = AudioAccessRecorder(initialVolume: 0.8)
    let ducker = AudioDucker(access: recorder.access, duckVolume: 0.2)
    ducker.snapshotBeforeCapture()
    ducker.duck()
    recorder.volume = 0.5
    recorder.operations.removeAll()

    ducker.restore()

    #expect(recorder.operations == ["read:7"])
    #expect(recorder.volume == 0.5)
}

private final class AudioAccessRecorder {
    var operations: [String] = []
    var volume: Float

    init(initialVolume: Float) {
        volume = initialVolume
    }

    lazy var access = AudioOutputAccess(
        defaultDevice: { [unowned self] in
            operations.append("defaultDevice")
            return 7
        },
        readVolume: { [unowned self] device in
            operations.append("read:\(device)")
            return volume
        },
        writeVolume: { [unowned self] device, value in
            operations.append("write:\(device):\(value)")
            volume = value
            return true
        }
    )
}
