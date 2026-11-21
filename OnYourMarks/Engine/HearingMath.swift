//
//  HearingMath.swift
//  OnYourMarks
//

import Foundation

/// Where to look for a signal in a recording. Times are on the host clock
/// as the sound is in the air at the microphone, before the input latency.
nonisolated struct HearingWindow: Equatable, Sendable {
    /// Where the onset is searched; nil if nothing is left to search.
    let search: ClosedRange<TimeInterval>?

    /// Where the background noise is measured.
    let noise: ClosedRange<TimeInterval>

    /// The search ends early because the signal was stopped.
    let isCutOff: Bool
}

/// Finding a signal in what the microphone recorded, and saying how far
/// that can be trusted. Kept free of audio hardware so it can be tested.
///
/// Nothing here needs the app to have played the signal: the window can
/// come from a schedule or from anywhere else, and the model to compare
/// with is optional.
nonisolated enum HearingMath {
    /// How long after the latest time the model allows the onset is still
    /// searched. More than a model that is off by a Bluetooth output's
    /// whole latency (180 ms) or an output 80 m away, and over before the
    /// gun's sound (0.37 s) when the built-in speaker plays it, so a start
    /// without athletes need not wait for the search.
    static let searchAfterModel: TimeInterval = 0.25

    /// Background noise is measured in this stretch before the render
    /// start, the earliest any of the signal can be in the air. The same as
    /// the calibration's: the hold before the gun is quiet.
    static let noiseWindow: ClosedRange<TimeInterval> = -0.15 ... -0.02

    /// How long past the end of the search the microphone may take to
    /// deliver it before what there is gets used: its chunks (21 ms at
    /// 48 kHz) and its input latency, many times over.
    static let deliveryAllowance: TimeInterval = 0.5

    /// How much of the newest audio a start's listener keeps: the noise
    /// before the gun, the search and its delivery, with room to spare.
    static let retention: TimeInterval = 3

    /// Either side of a heard onset: the microphone's own timing error, as
    /// in the calibration, and one sample for where between two samples the
    /// sound crossed the threshold. Reasoned; the calibration on the built-in
    /// speaker found its clicks within 0.1 ms of each other.
    static func timingUncertainty(sampleRate: Double) -> TimeInterval {
        CalibrationMath.measurementMargin + 1 / sampleRate
    }

    /// Where a signal the app scheduled can be heard: from its render start
    /// (no output plays a sound before it gets it) to a while after the
    /// latest time the model allows.
    ///
    /// A stop ends the search where the next sound could first be in the
    /// air, the earliest the model allows a sample rendered at the stop to
    /// be heard. Anything found before that is still this signal.
    static func window(for signal: ScheduledSignal, interruptedAt: MonotonicTimestamp?) -> HearingWindow {
        let renderStart = signal.renderStart.seconds
        let end = signal.audibleOnset.latest.seconds + searchAfterModel

        let earliestDelay = max(0, signal.audibleOnset.earliest.seconds - renderStart - signal.basis.onsetOffset)
        let cut = interruptedAt.map { $0.seconds + earliestDelay }
        let searchEnd = min(end, cut ?? end)

        return HearingWindow(
            search: searchEnd > renderStart ? renderStart ... searchEnd : nil,
            noise: (renderStart + noiseWindow.lowerBound) ... (renderStart + noiseWindow.upperBound),
            isCutOff: cut.map { $0 < end } ?? false
        )
    }

    /// The signal's onset in the recording, compared with the model.
    ///
    /// - Parameters:
    ///   - inputLatency: from sound reaching the microphone to the sample's
    ///     timestamp; taken out of the heard time.
    ///   - modelled: when the model says the output played the onset.
    ///   - travel: the sound's way from the output to the microphone, if known.
    static func hear(
        in chunks: [RecordedChunk],
        window: HearingWindow,
        inputLatency: TimeInterval,
        modelled: TimeEstimate?,
        travel: DurationEstimate?
    ) -> SignalHearing {
        guard let search = window.search else { return .notHeard(.stoppedBeforeHeard) }

        // The recording's timestamps are late by the input latency.
        let recordedSearch = (search.lowerBound + inputLatency) ... (search.upperBound + inputLatency)
        let recordedNoise = (window.noise.lowerBound + inputLatency) ... (window.noise.upperBound + inputLatency)

        guard let covered = CalibrationMath.gaplessCoverage(of: recordedSearch, in: chunks),
              CalibrationMath.covers(chunks, recordedNoise) else {
            return .notHeard(.noAudio)
        }

        guard let onset = CalibrationMath.detectOnset(in: chunks, window: recordedSearch, noiseWindow: recordedNoise) else {
            // The search only reaches the first gap; behind it the gun may be.
            guard covered.upperBound >= recordedSearch.upperBound else { return .notHeard(.noAudio) }

            return .notHeard(window.isCutOff ? .stoppedBeforeHeard : .nothingAboveNoise)
        }

        let best = onset.time - inputLatency
        let uncertainty = timingUncertainty(sampleRate: onset.sampleRate)

        return .heard(
            HeardSignal(
                heard: TimeEstimate(
                    best: MonotonicTimestamp(seconds: best),
                    earliest: MonotonicTimestamp(seconds: best - uncertainty),
                    latest: MonotonicTimestamp(seconds: best + uncertainty)
                ),
                modelled: modelled,
                travel: travel,
                inputLatency: inputLatency,
                peakLevel: Double(onset.peak),
                noiseLevel: Double(onset.noise)
            )
        )
    }
}
