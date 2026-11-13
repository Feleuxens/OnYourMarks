//
//  ReplayTimeline.swift
//  OnYourMarks
//

import CoreMedia
import Foundation

/// A recorded start laid out along its video: which frame shows which
/// moment, where the gun and the movements fall, and what the tracker knew
/// at each frame.
nonisolated struct ReplayTimeline: Equatable, Sendable {
    /// How old tracking data may be and still be drawn over a frame: two
    /// frames at the idle rate of 15 fps. Older than that, the skeleton
    /// would stand where the athlete no longer is.
    static let maximumTrackingAge: TimeInterval = 0.15

    let frameTimes: [MonotonicTimestamp]

    /// When the gun was heard; nil if the start never got that far. The
    /// time the reactions were measured against.
    let gun: TimeEstimate?

    let results: [AthleteStartResult]
    let roster: AthleteRoster?

    /// Ordered by time.
    private let tracking: [TrackingFrame]

    init(recording: StartRecording, tracking: [TrackingFrame]) {
        frameTimes = recording.frameTimes
        gun = Self.gun(in: recording.session)
        results = recording.results.sorted { ($0.position ?? .max) < ($1.position ?? .max) }
        roster = recording.session.roster
        self.tracking = tracking.sorted { $0.time < $1.time }
    }

    var frameCount: Int {
        frameTimes.count
    }

    /// From the first frame to the last.
    var duration: TimeInterval {
        guard let first = frameTimes.first, let last = frameTimes.last else { return 0 }
        return last.seconds - first.seconds
    }

    var falseStarters: Set<AthleteID> {
        Set(results.filter { $0.decision == .definiteFalseStart }.compactMap { $0.athleteID })
    }

    // MARK: - Frames

    /// Where a frame sits in the video.
    func videoTime(ofFrame frame: Int) -> CMTime {
        guard let first = frameTimes.first, frameTimes.indices.contains(frame) else { return .zero }
        return VideoTimeline.presentationTime(of: frameTimes[frame], first: first)
    }

    /// The frame on screen at a moment: the last one captured at or before
    /// it, the first frame for anything earlier.
    func frame(at time: MonotonicTimestamp) -> Int {
        max(0, frameTimes.partitioningIndex { $0 > time } - 1)
    }

    /// The frame on screen at a time in the video.
    func frame(atVideoTime seconds: TimeInterval) -> Int {
        guard let first = frameTimes.first else { return 0 }

        // A tick of the video's timescale, so a time that was rounded
        // down to a tick still finds its frame.
        let tolerance = 1 / Double(VideoTimeline.timescale)
        return frame(at: MonotonicTimestamp(seconds: first.seconds + seconds + tolerance))
    }

    /// The frame at a share of the video's length, as a scrubber gives it.
    func frame(atFraction fraction: Double) -> Int {
        frame(atVideoTime: fraction.clamped(to: 0...1) * duration)
    }

    /// Where a moment lies along the video, from 0 to 1; outside of the
    /// video, the nearer end.
    func fraction(of time: MonotonicTimestamp) -> Double {
        guard let first = frameTimes.first, duration > 0 else { return 0 }
        return ((time.seconds - first.seconds) / duration).clamped(to: 0...1)
    }

    /// How long after the gun's most likely time a frame was captured;
    /// negative before it. Nil without a gun.
    func timeSinceGun(ofFrame frame: Int) -> TimeInterval? {
        guard let gun, frameTimes.indices.contains(frame) else { return nil }
        return frameTimes[frame].seconds - gun.best.seconds
    }

    /// What the tracker knew when a frame was captured: the newest tracking
    /// data from that frame or shortly before it.
    func tracking(forFrame frame: Int) -> TrackingFrame? {
        guard frameTimes.indices.contains(frame) else { return nil }

        let time = frameTimes[frame]
        let index = tracking.partitioningIndex { $0.time > time } - 1

        guard index >= 0, time.seconds - tracking[index].time.seconds <= Self.maximumTrackingAge else { return nil }
        return tracking[index]
    }

    // MARK: - Gun

    /// The gun that was heard: the last one scheduled that was not taken
    /// back and whose time the sequence reached, as revised if it started
    /// off its schedule.
    static func gun(in session: StartSession) -> TimeEstimate? {
        var scheduled: TimeEstimate?
        var fired: TimeEstimate?

        for event in session.events {
            switch event.kind {
            case .gunScheduled:
                scheduled = event.time
            case .gunCancelled:
                scheduled = nil
            case .gunCommitted, .stateChanged(.start):
                fired = scheduled
            case .gunTimeRevised:
                fired = event.time
            default:
                break
            }
        }
        return fired
    }
}

nonisolated extension RandomAccessCollection {
    /// The index of the first element for which the predicate holds, in a
    /// collection where it holds for none and then for all; the end index
    /// if it holds for none.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int where Index == Int {
        var low = startIndex
        var high = endIndex

        while low < high {
            let middle = low + (high - low) / 2

            if predicate(self[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}
