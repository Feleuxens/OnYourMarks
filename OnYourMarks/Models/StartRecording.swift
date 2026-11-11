//
//  StartRecording.swift
//  OnYourMarks
//

import Foundation

/// One recorded start: everything the review shows beside the video.
///
/// The video itself is a clean picture in its own file; skeletons, markers
/// and times are drawn over it from this and from the tracking data, so
/// they can be analysed again or drawn differently later.
nonisolated struct StartRecording: Identifiable, Equatable, Codable, Sendable {
    let id: UUID

    /// When the recording began, for telling recordings apart. The times of
    /// the start itself are on the host clock, which means nothing after a restart.
    let date: Date

    let session: StartSession

    /// What every athlete that moved did, as the engine had it when the run ended.
    let results: [AthleteStartResult]

    /// Capture time of every frame in the video, in order, on the host
    /// clock the session's events use. Frame `n` sits in the video at its
    /// time minus the first one's.
    let frameTimes: [MonotonicTimestamp]

    /// Frames the camera delivered but the video writer could not take.
    /// They are missing from the video, not from the live analysis.
    let skippedFrames: Int
}

nonisolated extension StartSession {
    /// The athletes this start judged.
    var roster: AthleteRoster? {
        events.reversed().firstNonNil { event in
            if case .rosterEstablished(let roster) = event.kind { roster } else { nil }
        }
    }
}

nonisolated extension Sequence {
    func firstNonNil<Result>(_ transform: (Element) -> Result?) -> Result? {
        for element in self {
            if let result = transform(element) { return result }
        }
        return nil
    }
}
