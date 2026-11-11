//
//  ScheduledSignal.swift
//  OnYourMarks
//

import AVFAudio

/// A signal placed on the audio clock, and when it reaches the listener.
nonisolated struct ScheduledSignal: Equatable, Sendable {
    let signal: Signal

    /// Host time at which the engine renders the buffer's first sample.
    let renderStart: MonotonicTimestamp

    /// When the sound's audible onset leaves the output device.
    /// Render start + output latency + onset offset in the file,
    /// widened by how far the route's reported latency can be trusted.
    let audibleOnset: TimeEstimate

    /// What the audible onset was derived from.
    let basis: SignalTimingBasis
}

/// Everything that turns a render time into the moment a signal is heard.
/// Kept with the start, so a close decision can be traced back later.
nonisolated struct SignalTimingBasis: Equatable, Codable, Sendable {
    let route: OutputRoute?

    /// As reported by the system for the route.
    let outputLatency: TimeInterval

    /// Where the audible transient sits in the sound file.
    let onsetOffset: TimeInterval

    /// The calibration that was applied, if the route has one.
    let calibration: OutputCalibration?

    let uncertainty: TimeInterval

    func audibleOnset(renderStart: MonotonicTimestamp) -> TimeEstimate {
        OutputTiming.audibleOnset(
            renderStart: renderStart,
            latency: outputLatency,
            onsetOffset: onsetOffset,
            correction: calibration?.correction ?? 0,
            uncertainty: uncertainty
        )
    }
}

/// How render time maps to the moment a sound is heard.
///
/// The uncertainties are starting assumptions, not measurements yet:
/// wired and built-in outputs report their hardware latency, while wireless
/// routes add buffering the system only estimates. Calibrate them with a
/// recording of the real output before relying on decisions near the threshold.
nonisolated enum OutputTiming {
    /// Uncertainty for the built-in speaker and wired outputs.
    static let wiredUncertainty: TimeInterval = 0.002

    /// How far a measured start may be from its schedule before the
    /// schedule counts as missed: a quarter of the wired budget.
    /// An iPhone 17 Pro speaker measured about 80 µs.
    static let maximumScheduleDeviation: TimeInterval = 0.000_5
    
    /// Lower bound for wireless routes (Bluetooth, AirPlay, CarPlay).
    static let minimumWirelessUncertainty: TimeInterval = 0.020

    /// Share of the reported latency a wireless route may be off by.
    static let wirelessUncertaintyShare = 0.5

    static let wirelessPorts: Set<AVAudioSession.Port> = [
        .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay, .carAudio
    ]

    /// Scheduling closer than this risks the render cycle having already
    /// passed, which makes the player start "now" at an unknown point.
    static func minimumLead(ioBufferDuration: TimeInterval) -> TimeInterval {
        2 * ioBufferDuration + 0.005
    }

    static func uncertainty(
        latency: TimeInterval,
        isWireless: Bool
    ) -> TimeInterval {
        guard isWireless else { return wiredUncertainty }

        return max(minimumWirelessUncertainty, latency * wirelessUncertaintyShare)
    }
    
    /// A calibration replaces the assumption, but never claims more
    /// precision than a wired output has.
    static func uncertainty(calibrated calibration: OutputCalibration) -> TimeInterval {
        max(calibration.uncertainty, wiredUncertainty)
    }

    /// `correction` comes from a calibration of the output, if there is one.
    static func audibleOnset(
        renderStart: MonotonicTimestamp,
        latency: TimeInterval,
        onsetOffset: TimeInterval,
        correction: TimeInterval = 0,
        uncertainty: TimeInterval
    ) -> TimeEstimate {
        let best = renderStart.seconds + latency + onsetOffset + correction

        return TimeEstimate(
            best: MonotonicTimestamp(seconds: best),
            earliest: MonotonicTimestamp(seconds: best - uncertainty),
            latest: MonotonicTimestamp(seconds: best + uncertainty)
        )
    }
}
