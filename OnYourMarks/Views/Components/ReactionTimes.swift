//
//  ReactionTimes.swift
//  OnYourMarks
//

import SwiftUI

/// The reaction of every athlete that moved in the latest start: the
/// number the preview shows above them, the time, and how far it may be off.
struct ReactionTimes: View {
    let results: [AthleteStartResult]
    /// Marked among the others, where one can be picked.
    var selected: AthleteID?
    /// Makes the times tappable.
    var onSelect: ((AthleteStartResult) -> Void)?
    /// The second pass over the recorded video, shown under each live time.
    var analysis: RecordingAnalysis?
    /// Whether the second pass is still running.
    var isAnalysing = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                    if let onSelect {
                        Button {
                            onSelect(result)
                        } label: {
                            chip(for: result)
                        }
                        .buttonStyle(.plain)
                    } else {
                        chip(for: result)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("reactionTimes")
    }
    
    private func chip(for result: AthleteStartResult) -> some View {
        HStack(spacing: 6) {
            if let position = result.position {
                Text(position, format: .number)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(color(for: result.decision), in: Circle())
            }
            
            VStack(alignment: .leading, spacing: 2) {
                if let reaction = result.reactionMilliseconds, let tolerance = result.reactionToleranceMilliseconds {
                    // The tolerance belongs to the number: it is a measurement, not a verdict.
                    Text("\(reaction) ms ± \(tolerance) ms")
                } else {
                    Text("Before the gun")
                }

                secondPass(for: result)
            }
        }
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.leading, result.position == nil ? 12 : 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay {
            if result.athleteID != nil, result.athleteID == selected {
                Capsule().strokeBorder(.white, lineWidth: 2)
            } else if result.position == nil {
                Capsule().strokeBorder(color(for: result.decision), lineWidth: 2)
            }
        }
    }
    
    /// What the second pass found for the athlete, smaller under the live
    /// time. Only a measurement: the decision stays the live one.
    @ViewBuilder
    private func secondPass(for result: AthleteStartResult) -> some View {
        Group {
            if let athlete = analysis?.athlete(result.athleteID) {
                if let reaction = athlete.reaction?.milliseconds, let tolerance = athlete.reaction?.toleranceMilliseconds {
                    Text("From the video: \(reaction) ms ± \(tolerance) ms")
                } else if athlete.movement != nil {
                    Text("From the video: before the gun")
                } else {
                    Text("From the video: not found")
                }
            } else if isAnalysing {
                Text("Analysing the video…")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white.opacity(0.75))
        .accessibilityIdentifier("secondPassReaction")
    }

    private func color(for decision: StartDecision) -> Color {
        decision.color
    }
}

nonisolated extension AthleteStartResult {
    /// The most likely reaction time; nil for a movement before the gun.
    var reactionMilliseconds: Int? {
        reaction?.milliseconds
    }

    /// How far the reaction may be off to either side, rounded up so the
    /// display never promises more than was measured.
    var reactionToleranceMilliseconds: Int? {
        reaction?.toleranceMilliseconds
    }
}

nonisolated extension DurationEstimate {
    /// The most likely value, in whole milliseconds.
    var milliseconds: Int {
        Int((best * 1000).rounded())
    }

    /// How far the value may be off to either side, rounded up so the
    /// display never promises more than was measured.
    var toleranceMilliseconds: Int {
        Int((max(best - earliest, latest - best) * 1000).rounded(.up))
    }
}
