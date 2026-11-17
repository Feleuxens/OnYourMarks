//
//  RecordedStart.swift
//  OnYourMarks
//

import Foundation

/// One recorded start as its folder holds it: everything the app's own
/// logic needs to run over the start again, without the camera.
nonisolated struct RecordedStart: Sendable {
    let directory: URL
    let recording: StartRecording
    let tracking: [TrackingFrame]
    /// Empty for a start without samples (handheld, or nobody in view).
    let motion: [MotionRecord]
    /// What a person found in the video, if someone labelled it.
    let truth: RecordedTruth?
    /// The second pass over the video, if it ran.
    let analysis: RecordingAnalysis?

    var videoURL: URL {
        directory.appending(path: RecordingStore.videoFileName)
    }

    /// Reads a recording's folder. The record and the tracking data must be
    /// there; the samples, the truth and the analysis may be missing.
    static func load(from directory: URL) throws -> RecordedStart {
        let decoder = JSONDecoder()

        func optional<Value: Decodable>(_ type: Value.Type, _ name: String) throws -> Value? {
            let file = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try decoder.decode(type, from: Data(contentsOf: file))
        }

        return RecordedStart(
            directory: directory,
            recording: try decoder.decode(
                StartRecording.self,
                from: Data(contentsOf: directory.appending(path: RecordingStore.recordFileName))
            ),
            tracking: try decoder.decode(
                [TrackingFrame].self,
                from: Data(contentsOf: directory.appending(path: RecordingStore.trackingFileName))
            ),
            motion: try optional([MotionRecord].self, RecordingStore.motionFileName) ?? [],
            truth: try optional(RecordedTruth.self, RecordingStore.truthFileName),
            analysis: try optional(RecordingAnalysis.self, RecordingStore.analysisFileName)
        )
    }

    /// The recordings in a folder: the folder itself if it is one, else
    /// every folder in it that holds a record, by name.
    static func folders(in directory: URL) -> [URL] {
        let isRecording = { (folder: URL) in
            FileManager.default.fileExists(atPath: folder.appending(path: RecordingStore.recordFileName).path)
        }

        guard !isRecording(directory) else { return [directory] }

        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter(isRecording).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// What a person found by looking at a recorded start's video frame by
/// frame, kept beside it as `truth.json`. Nothing writes it; it is labelled
/// by hand, so that the replay and the second pass can be checked against
/// something other than themselves.
///
/// ```json
/// { "method": "review at 10 %, frame by frame",
///   "athletes": [ { "position": 1, "firstMovingFrame": 712 } ] }
/// ```
nonisolated struct RecordedTruth: Equatable, Codable, Sendable {
    struct Athlete: Equatable, Codable, Sendable {
        /// The athlete's number on the roster, counted from the left as the
        /// preview and the review show it.
        let position: Int

        /// The first frame in which the person sees the movement, numbered
        /// from 1 as the review shows it ("Frame n of N"). The movement
        /// began after the frame before it.
        let firstMovingFrame: Int

        let note: String?
    }

    let athletes: [Athlete]

    /// How the frames were found, e.g. at which speed and by whom.
    let method: String?

    /// Between the last frame the person saw at rest and the first one in
    /// which they saw the movement. Nil for a frame the video doesn't have.
    func movement(of athlete: Athlete, frameTimes: [MonotonicTimestamp]) -> TimeEstimate? {
        let first = athlete.firstMovingFrame - 1

        guard first >= 1, first < frameTimes.count else { return nil }

        return TimeEstimate(
            best: MonotonicTimestamp(seconds: (frameTimes[first - 1].seconds + frameTimes[first].seconds) / 2),
            earliest: frameTimes[first - 1],
            latest: frameTimes[first]
        )
    }
}
