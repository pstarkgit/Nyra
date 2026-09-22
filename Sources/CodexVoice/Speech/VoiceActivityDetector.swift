import Foundation

enum VoiceActivityEvent: Equatable, Sendable {
    case speechStarted
    case utteranceEnded
}

struct VoiceActivityDetector: Sendable {
    let speechThreshold: Float
    let minimumSpeech: TimeInterval
    let trailingSilence: TimeInterval

    private(set) var hasDetectedSpeech = false
    private var ended = false
    private var speechDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0

    init(
        speechThreshold: Float = 0.005,
        minimumSpeech: TimeInterval = 0.18,
        trailingSilence: TimeInterval = 0.60
    ) {
        self.speechThreshold = max(0, speechThreshold)
        self.minimumSpeech = max(0, minimumSpeech)
        self.trailingSilence = max(0, trailingSilence)
    }

    mutating func consume(
        rms: Float,
        frameDuration: TimeInterval
    ) -> VoiceActivityEvent? {
        guard !ended, frameDuration > 0 else { return nil }
        if rms >= speechThreshold {
            silenceDuration = 0
            if !hasDetectedSpeech {
                speechDuration += frameDuration
                if speechDuration + 0.000_001 >= minimumSpeech {
                    hasDetectedSpeech = true
                    return .speechStarted
                }
            }
            return nil
        }

        if !hasDetectedSpeech {
            speechDuration = 0
            return nil
        }
        silenceDuration += frameDuration
        if silenceDuration + 0.000_001 >= trailingSilence {
            ended = true
            return .utteranceEnded
        }
        return nil
    }

    mutating func reset() {
        hasDetectedSpeech = false
        ended = false
        speechDuration = 0
        silenceDuration = 0
    }
}

enum AudioLevel {
    static func rms(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(Float.zero) { partial, value in
            partial + value * value
        } / Float(samples.count)
        return sqrt(meanSquare)
    }
}
