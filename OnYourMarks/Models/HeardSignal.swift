//
//  HeardSignal.swift
//  OnYourMarks
//

import Foundation

/// A signal as the phone's microphone picked it up, and how that compares
/// with when the timing model says the output played it.
///
/// The microphone hears a sound later than the output plays it, by the
/// sound's way between them. That way is only known for the built-in
/// speaker. From any other output, heard minus modelled is the travel
/// time plus the model's error, and one microphone can't tell the two
/// apart: `travel` is nil then, and the comparison only claims what holds
/// for any distance.
nonisolated struct HeardSignal: Equatable, Codable, Sendable {
    /// When the onset reached the microphone, on the host clock, with the
    /// input latency taken out.
    let heard: TimeEstimate

    /// When the timing model says the output played the onset. Nil for a
    /// sound the app did not play, like a starter's pistol.
    let modelled: TimeEstimate?

    /// How long the sound takes from the output to this microphone, if known.
    let travel: DurationEstimate?

    /// What was taken out of the samples' timestamps. Kept so the
    /// measurement can be worked out again.
    let inputLatency: TimeInterval

    /// Peak magnitude in the search and RMS of the noise before it, as
    /// sample values: how clearly the onset stood out.
    let peakLevel: Double
    let noiseLevel: Double

    /// Metres per second, in air at 20 °C.
    static let speedOfSound = 343.0

    /// The built-in speakers and microphones are on the same phone, at most
    /// its length apart (an iPhone 17 Pro is 15 cm long). The microphone
    /// next to the bottom speaker is much closer, but which speaker it
    /// hears first isn't known.
    static let builtInSpeakerTravel = DurationEstimate(best: 0, earliest: 0, latest: 0.15 / speedOfSound)

    /// Heard minus modelled: the sound's way to the microphone plus
    /// whatever the model is off by. Nil without a model.
    var heardAfterModel: DurationEstimate? {
        modelled.map { heard.duration(since: $0) }
    }

    /// How far the model is off once the sound's way is taken out. Nil
    /// if the way or the model is unknown.
    var modelError: DurationEstimate? {
        guard let delay = heardAfterModel, let travel else { return nil }

        return DurationEstimate(
            best: delay.best - travel.best,
            earliest: delay.earliest - travel.latest,
            latest: delay.latest - travel.earliest
        )
    }

    var check: ModelCheck {
        guard let delay = heardAfterModel else { return .noModel }

        // Any distance only makes the sound later, so a sound heard before
        // the model allows contradicts it however far the output is.
        if delay.latest < (travel?.earliest ?? 0) {
            return .heardEarlier
        }

        guard let error = modelError else { return .undecided }

        if error.earliest > 0 {
            return .heardLater
        }
        return .agrees
    }

    /// How far the output would be from the microphone if the model were
    /// right, in metres. Nil when it contradicts the model or there is none.
    var distanceIfModelHolds: ClosedRange<Double>? {
        guard let delay = heardAfterModel, check != .heardEarlier else { return nil }

        return max(0, delay.earliest) * Self.speedOfSound ... max(0, delay.latest) * Self.speedOfSound
    }
}

/// What a heard signal says about the timing model.
nonisolated enum ModelCheck: Equatable, Sendable {
    /// The measurement and the model's interval overlap.
    case agrees

    /// Heard later than the model allows, even after the sound's way.
    case heardLater

    /// Heard before the model allows; no distance explains that.
    case heardEarlier

    /// Heard after the model, by a time the unknown way from the output
    /// may account for.
    case undecided

    /// Nothing to compare with.
    case noModel
}

/// Why a signal the microphone listened for was not found.
nonisolated enum SignalNotHeard: Equatable, Codable, Sendable {
    /// The microphone delivered nothing for the time the signal could be heard in.
    case noAudio

    /// Nothing rose far enough above the noise before it: the output may
    /// have been muted or too quiet, or the surroundings too loud.
    case nothingAboveNoise

    /// The signal was stopped before it could be heard, e.g. by a recall.
    case stoppedBeforeHeard
}

/// What listening for a signal came to.
nonisolated enum SignalHearing: Equatable, Sendable {
    /// The session records nothing (as in `.playback`), so nothing was heard or missed.
    case notListening

    case heard(HeardSignal)

    case notHeard(SignalNotHeard)
}
