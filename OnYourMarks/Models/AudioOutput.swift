//
//  AudioOutput.swift
//  OnYourMarks
//

import Foundation

/// Where the start signals play.
nonisolated enum AudioOutput: String, Codable, CaseIterable, Sendable {
    /// Follows the system route, e.g. Bluetooth headphones when connected.
    case automatic

    /// Always the built-in speaker, even while other audio plays over Bluetooth.
    /// iOS only allows this in a recording category, so it needs microphone access.
    case iPhoneSpeaker
}

/// An output port, as far as calibrations are concerned.
nonisolated struct OutputRoute: Equatable, Codable, Sendable {
    /// Stable per device, e.g. a Bluetooth headphone's address.
    let id: String
    let name: String
    let isWireless: Bool
    let isBuiltInSpeaker: Bool
}

/// The measured difference between when the timing model expects a sound
/// to be heard on an output and when the microphone actually picked it up.
nonisolated struct OutputCalibration: Codable, Equatable, Sendable {
    let routeID: String
    let routeName: String
    let isBuiltInSpeaker: Bool

    /// Added to the model's audible onset. Positive means heard later than predicted.
    let correction: TimeInterval

    /// How far a single measurement may be off, from the spread of the clicks.
    let uncertainty: TimeInterval

    let clickCount: Int
    let date: Date
}
