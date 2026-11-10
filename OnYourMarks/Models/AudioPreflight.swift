//
//  AudioPreflight.swift
//  OnYourMarks
//

import Foundation

/// What the silent check before a start found the audio output to be.
nonisolated struct AudioPreflight: Equatable, Sendable {
    /// Hardware sample rate of the output.
    let sampleRate: Double
    let ioBufferDuration: TimeInterval

    /// How the gun's render time will map to the moment it is heard.
    let gunTiming: SignalTimingBasis

    /// A wireless output's latency is only an estimate until it is calibrated.
    var isCalibrationMissing: Bool {
        gunTiming.route?.isWireless == true && gunTiming.calibration == nil
    }
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
