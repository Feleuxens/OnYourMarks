//
//  AudioPreflight.swift
//  OnYourMarks
//

import Foundation

/// What the silent check before a start found the audio output to be.
nonisolated struct AudioPreflight: Equatable, Codable, Sendable {
    /// Hardware sample rate of the output.
    let sampleRate: Double
    let ioBufferDuration: TimeInterval

    /// How the gun's render time will map to the moment it is heard.
    let gunTiming: SignalTimingBasis

    /// The microphone the start listens for its gun with. Nil when the
    /// session records nothing, and in starts recorded before there was one.
    var microphone: MicrophoneInput?

    /// A wireless output's latency is only an estimate until it is calibrated.
    var isCalibrationMissing: Bool {
        gunTiming.isCalibrationMissing
    }
}

/// The microphone a start listens with.
nonisolated struct MicrophoneInput: Equatable, Codable, Sendable {
    let name: String
    let sampleRate: Double

    /// Taken out of every sample's timestamp, as the system reports it.
    let inputLatency: TimeInterval
}

nonisolated enum PreflightError: LocalizedError, Equatable {
    case soundMissing
    case engineNotRunning
    case noOutput
    case speakerUnavailable(current: String)

    var errorDescription: String? {
        switch self {
        case .soundMissing:
            String(localized: "A start sound could not be loaded.")
        case .engineNotRunning:
            String(localized: "The audio engine could not be started.")
        case .noOutput:
            String(localized: "No audio output is available.")
        case .speakerUnavailable(let current):
            String(localized: "The iPhone speaker could not be selected; the signals would play on \(current).")
        }
    }
}
