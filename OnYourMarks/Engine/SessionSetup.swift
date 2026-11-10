//
//  SessionSetup.swift
//  OnYourMarks
//

import AVFAudio

/// How the audio session is configured for an output and a purpose.
nonisolated struct SessionSetup: Equatable, Sendable {
    let category: AVAudioSession.Category
    let options: AVAudioSession.CategoryOptions

    /// Overrides the route to the built-in speaker after activation.
    let forcesSpeaker: Bool

    var needsMicrophone: Bool { category == .playAndRecord }

    /// For starts: only forcing the speaker needs a recording category.
    static func forStarts(on output: AudioOutput) -> SessionSetup {
        switch output {
        case .automatic:
            SessionSetup(category: .playback, options: [], forcesSpeaker: false)
        case .iPhoneSpeaker:
            speaker
        }
    }

    /// For calibration: recording through the built-in microphone while
    /// playing on the same output the starts use.
    static func forCalibration(on output: AudioOutput) -> SessionSetup {
        switch output {
        case .automatic:
            // A2DP keeps Bluetooth headphones as the output; without HFP the
            // microphone stays the built-in one.
            SessionSetup(
                category: .playAndRecord,
                options: [.allowBluetoothA2DP, .defaultToSpeaker],
                forcesSpeaker: false
            )
        case .iPhoneSpeaker:
            speaker
        }
    }

    /// Without Bluetooth options, Bluetooth isn't an available output, and
    /// `defaultToSpeaker` picks the speaker over the earpiece.
    private static let speaker = SessionSetup(
        category: .playAndRecord,
        options: [.defaultToSpeaker],
        forcesSpeaker: true
    )
}
