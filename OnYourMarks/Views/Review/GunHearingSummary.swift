//
//  GunHearingSummary.swift
//  OnYourMarks
//

import SwiftUI

/// What the microphone heard of the gun, against when the timing model
/// says it played. Only says what the measurement carries: from an output
/// away from the phone, the sound's way and the model's error look alike.
struct GunHearingSummary: View {
    let hearing: SignalHearing

    var body: some View {
        if let text {
            text
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("replayGunHearing")
        }
    }

    private var text: Text? {
        switch hearing {
        case .notListening:
            nil
        case .heard(let heard):
            text(for: heard)
        case .notHeard(.noAudio):
            Text("Microphone: no recording of the gun.")
        case .notHeard(.nothingAboveNoise):
            Text("Microphone: the gun did not stand out from the noise.")
        case .notHeard(.stoppedBeforeHeard):
            Text("Microphone: the gun was stopped before it could be heard.")
        }
    }

    private func text(for heard: HeardSignal) -> Text {
        guard let delay = heard.heardAfterModel else {
            return Text("Microphone: gun heard.")
        }

        let milliseconds = (delay.best * 1000).formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))

        switch heard.check {
        case .agrees:
            return Text("Microphone: gun heard \(milliseconds) ms from the model, within its range.")
        case .heardLater, .heardEarlier:
            return Text("Microphone: gun heard \(milliseconds) ms from the model, outside its range.")
        case .undecided:
            let distance = heard.distanceIfModelHolds.map { range in
                let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
                return "\(range.lowerBound.formatted(format))–\(range.upperBound.formatted(format))"
            } ?? "?"
            return Text("Microphone: gun heard \(milliseconds) ms after the model; the speaker is \(distance) m away or the model is off.")
        case .noModel:
            return Text("Microphone: gun heard.")
        }
    }
}
