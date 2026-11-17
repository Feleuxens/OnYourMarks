//
//  CancellationLeadMath.swift
//  OnYourMarks
//

import Foundation

/// One scheduled gun stopped shortly before (or after) its render start,
/// and what got out of it: the measurement behind
/// `OutputTiming.cancellationLead`.
nonisolated struct CancellationTrial: Equatable, Sendable {
    /// How long before the render start the stop was called; negative after it.
    let stopLead: TimeInterval

    /// How long the stop call took.
    let stopDuration: TimeInterval

    /// What the playback engine's mixer put out of the gun.
    let rendered: RenderedSound

    /// Peak at the microphone over the RMS of the noise before, as an
    /// amplitude ratio; nil without a microphone.
    let heardRatio: Double?

    /// Whether the microphone picked the gun up, by the calibration's
    /// signal-to-noise rule.
    var heard: Bool? {
        heardRatio.map { $0 >= Double(CalibrationMath.minimumSignalToNoise) }
    }

    /// Any of the gun got out: the mixer rendered some of it. What the
    /// mixer renders is played, whatever the output; the microphone only
    /// confirms it and also picks up the room.
    var leaked: Bool {
        rendered.duration > 0
    }
}

/// The part of a sound a mixer rendered.
nonisolated struct RenderedSound: Equatable, Sendable {
    /// From the first to the last sample that isn't silence; zero if none.
    let duration: TimeInterval

    /// The first such sample against the render start; nil if none.
    let firstSample: TimeInterval?

    /// Peak magnitude.
    let peak: Float

    static let nothing = RenderedSound(duration: 0, firstSample: nil, peak: 0)
}

/// Reads the trials of a cancellation measurement. Kept free of audio
/// hardware so it can be tested.
nonisolated enum CancellationLeadMath {
    /// Above this the mixer's output counts as sound. It puts out exact zeros
    /// while no player plays; −140 dBFS is far below anything a speaker
    /// reproduces and far above rounding.
    static let silence: Float = 1e-7

    /// The mixer can't render a sound before its render start; this much
    /// earlier is still looked at, for where the tap's timestamps put it.
    static let renderSearchBefore: TimeInterval = 0.05

    /// What the mixer rendered of a sound due at `renderStart`, looking
    /// until `end`. Times are the tap's, on the render timeline.
    static func rendered(in chunks: [RecordedChunk], renderStart: TimeInterval, through end: TimeInterval) -> RenderedSound {
        let from = renderStart - renderSearchBefore
        var first: TimeInterval?
        var last: TimeInterval?
        var peak: Float = 0

        for chunk in chunks where chunk.end > from && chunk.hostSeconds <= end {
            for (index, value) in chunk.samples.enumerated() {
                let time = chunk.hostSeconds + Double(index) / chunk.sampleRate
                guard time >= from, time <= end, abs(value) > silence else { continue }

                first = first ?? time
                last = time + 1 / chunk.sampleRate
                peak = max(peak, abs(value))
            }
        }

        guard let first, let last else { return .nothing }
        return RenderedSound(duration: last - first, firstSample: first - renderStart, peak: peak)
    }

    /// Peak magnitude in `window` over the RMS in `noise`; nil if the
    /// recording doesn't cover both.
    static func peakToNoise(in chunks: [RecordedChunk], window: ClosedRange<TimeInterval>, noise: ClosedRange<TimeInterval>) -> Double? {
        var peak: Float = 0
        var squares: Double = 0
        var noiseCount = 0
        var windowCount = 0

        for chunk in chunks {
            for (index, value) in chunk.samples.enumerated() {
                let time = chunk.hostSeconds + Double(index) / chunk.sampleRate

                if window.contains(time) {
                    peak = max(peak, abs(value))
                    windowCount += 1
                }
                if noise.contains(time) {
                    squares += Double(value * value)
                    noiseCount += 1
                }
            }
        }

        guard windowCount > 0, noiseCount > 0 else { return nil }

        let rms = (squares / Double(noiseCount)).squareRoot()
        return Double(peak) / max(rms, Double(silence))
    }

    /// What the trials say about the lead.
    struct Summary: Equatable, Sendable {
        /// The longest lead at which something still got out.
        let largestLeakingLead: TimeInterval?

        /// The shortest lead tried above every leaking one: the smallest lead
        /// that never let sound through. Nil if no trial above them all.
        let smallestCleanLead: TimeInterval?

        /// The longest lead at which the microphone heard something, to
        /// compare: a noise in the room counts here too.
        let largestHeardLead: TimeInterval?
    }

    static func summarize(_ trials: [CancellationTrial]) -> Summary {
        let largestLeaking = trials.filter(\.leaked).map(\.stopLead).max()

        let clean = trials
            .filter { trial in largestLeaking.map { trial.stopLead > $0 } ?? true }
            .map(\.stopLead)
            .min()

        let largestHeard = trials.filter { $0.heard == true }.map(\.stopLead).max()

        return Summary(largestLeakingLead: largestLeaking, smallestCleanLead: clean, largestHeardLead: largestHeard)
    }

    /// The leads to try: from one I/O cycle after the render start, which
    /// must let the gun through, to two cycles beyond the current lead, in
    /// quarter cycles.
    static func leadsToTry(ioBufferDuration: TimeInterval) -> [TimeInterval] {
        let current = OutputTiming.cancellationLead(ioBufferDuration: ioBufferDuration)
        let step = ioBufferDuration / 4
        let last = max(current + 2 * ioBufferDuration, 3 * ioBufferDuration)

        var leads = Array(stride(from: -ioBufferDuration, through: last + step / 2, by: step))
        if !leads.contains(where: { abs($0 - current) < step / 10 }) {
            leads.append(current)
        }
        return leads.sorted()
    }
}
