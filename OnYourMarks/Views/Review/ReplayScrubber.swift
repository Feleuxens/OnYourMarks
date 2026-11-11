//
//  ReplayScrubber.swift
//  OnYourMarks
//

import SwiftUI

/// The video as a line: where the gun was heard, where each athlete began
/// to move, and where the frame on screen lies. Dragging moves through
/// the frames.
///
/// The gun and the movements are drawn as wide as they are uncertain.
struct ReplayScrubber: View {
    let timeline: ReplayTimeline
    let progress: Double
    var highlighted: AthleteID?
    let onScrub: (Double) -> Void

    /// Narrower than this an interval could not be seen.
    private static let minimumMarkerWidth: CGFloat = 3
    private static let trackHeight: CGFloat = 6
    private static let markerHeight: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(height: Self.trackHeight)

                if let gun = timeline.gun {
                    marker(for: gun, in: width, color: .yellow, height: Self.markerHeight + 10)
                }

                ForEach(Array(timeline.results.enumerated()), id: \.offset) { _, result in
                    marker(for: result.movement, in: width, color: result.decision.color, height: Self.markerHeight)
                        .opacity(highlighted == nil || highlighted == result.athleteID ? 1 : 0.35)
                }

                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .offset(x: progress * width - 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard width > 0 else { return }
                    onScrub(value.location.x / width)
                }
            )
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityIdentifier("replayScrubber")
        .accessibilityLabel("Position in the video")
        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onScrub(min(1, progress + 0.05))
            case .decrement: onScrub(max(0, progress - 0.05))
            @unknown default: break
            }
        }
    }

    private func marker(for time: TimeEstimate, in width: CGFloat, color: Color, height: CGFloat) -> some View {
        let start = timeline.fraction(of: time.earliest) * width
        let end = timeline.fraction(of: time.latest) * width
        let markerWidth = max(end - start, Self.minimumMarkerWidth)

        return RoundedRectangle(cornerRadius: 1.5)
            .fill(color)
            .frame(width: markerWidth, height: height)
            .offset(x: (start + end) / 2 - markerWidth / 2)
    }
}

extension StartDecision {
    /// How a decision is coloured wherever it is shown.
    var color: Color {
        switch self {
        case .definiteFalseStart: .red
        case .uncertain: .orange
        case .legal: .green
        case .notApplicable: .gray
        }
    }
}
