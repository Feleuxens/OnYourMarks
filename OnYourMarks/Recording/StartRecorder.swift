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

    /// The run is over. The recorder may go on for a moment to show how the
    /// start went on, and keeps the recording only if the start got as far
    /// as a gun or a false start.
    func endRecording(session: StartSession, results: [AthleteStartResult])
}

/// Where a recorder gets the camera's frames.
protocol FrameSource: AnyObject {
    /// Whether frames are arriving.
    var isDelivering: Bool { get }

    /// Receives every frame on the capture queue, after the analysis. It
    /// must return quickly and must not keep the frame's buffer.
    func setRecordingHandler(_ handler: (@Sendable (CameraFrame) -> Void)?)
}
