//
//  ReactionTimes.swift
//  OnYourMarks
//

import SwiftUI

/// The reaction of every athlete that moved in the latest start: the
/// number the preview shows above them, the time, and how far it may be off.
struct ReactionTimes: View {
    let results: [AthleteStartResult]
    
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                    chip(for: result)
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
            
            if let reaction = result.reactionMilliseconds, let tolerance = result.reactionToleranceMilliseconds {
                // The tolerance belongs to the number: it is a measurement, not a verdict.
                Text("\(reaction) ms ± \(tolerance) ms")
            } else {
                Text("Before the gun")
            }
        }
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.leading, result.position == nil ? 12 : 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay {
            if result.position == nil {
                Capsule().strokeBorder(color(for: result.decision), lineWidth: 2)
            }
        }
    }
    
    private func color(for decision: StartDecision) -> Color {
        switch decision {
        case .definiteFalseStart: .red
        case .uncertain: .orange
        case .legal: .green
        case .notApplicable: .gray
        }
    }
}

nonisolated extension AthleteStartResult {
    /// The most likely reaction time; nil for a movement before the gun.
    var reactionMilliseconds: Int? {
        reaction.map { Int(($0.best * 1000).rounded()) }
    }
    
    /// How far the reaction may be off to either side, rounded up so the
    /// display never promises more than was measured.
    var reactionToleranceMilliseconds: Int? {
        reaction.map { Int((max($0.best - $0.earliest, $0.latest - $0.best) * 1000).rounded(.up)) }
    }
}
