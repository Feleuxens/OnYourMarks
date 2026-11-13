//
//  StartRecorder.swift
//  OnYourMarks
//

import Foundation

/// Records a start for the review. The engine says when; what is recorded
/// and where it goes is the recorder's business.
protocol StartRecorder: AnyObject {
    /// Begins recording. False if there is nothing to record, e.g. the
    /// camera is off.
    func beginRecording() -> Bool

    /// The athletes of one analysed frame. Ignored outside of a recording.
    func record(_ frame: TrackingFrame)

    /// What the detector's sampler saw of one athlete, frame by frame.
    /// Ignored outside of a recording.
    func record(_ motion: MotionRecord)

    /// The run is over. After a completed start the recorder goes on for
    /// `tail` seconds to show how the start went on. It keeps the recording
    /// only if the start got as far as a gun or a false start.
    func endRecording(session: StartSession, results: [AthleteStartResult], tail: TimeInterval)
}

/// Where a recorder gets the camera's frames.
protocol FrameSource: AnyObject {
    /// Whether frames are arriving.
    var isDelivering: Bool { get }

    /// Receives every frame on the capture queue, after the analysis. It
    /// must return quickly and must not keep the frame's buffer.
    func setRecordingHandler(_ handler: (@Sendable (CameraFrame) -> Void)?)
}
