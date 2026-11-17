//
//  CameraReport.swift
//  OnYourMarks
//

import Foundation

/// Why frames stopped arriving.
nonisolated enum CameraFault: Equatable, Codable, Sendable {
    /// The system took the camera away; raw value of
    /// `AVCaptureSession.InterruptionReason`, if it said.
    case interrupted(reason: Int?)

    /// The session stopped with an error.
    case runtimeError(String)

    /// Nothing arrived for longer than the camera ever pauses
    /// (`FrameFlow.stallTimeout`), without the system saying why.
    case framesStopped
}

/// What a start depends on of the camera a detector watches through.
nonisolated enum CameraCondition: Equatable, Sendable {
    /// No camera in use. The detector sees no one, and a start works without it.
    case off

    /// Switched on, no frame there yet.
    case starting

    /// Frames are arriving. Steady once, in the precision window, the rate
    /// has arrived (or was given up on) and exposure, focus and white
    /// balance are held; outside the window never.
    case delivering(isSteady: Bool)

    case failed(CameraFault)
}

/// How the camera was set up when a start was prepared.
nonisolated struct CameraSetup: Equatable, Codable, Sendable {
    let width: Int
    let height: Int
    /// The precision rate the settings ask for.
    let requestedFrameRate: Double
    /// The precision rate the format can deliver: the one asked for, or the
    /// fastest the camera has.
    let expectedFrameRate: Double
}

/// How the precision rate came about in one precision window.
nonisolated struct PrecisionRateReport: Equatable, Codable, Sendable {
    nonisolated enum Outcome: String, Equatable, Codable, Sendable {
        /// The running session switched to the rate by itself.
        case arrived
        /// Only after the session was restarted at the rate.
        case arrivedAfterRestart
        /// Not even then; the start goes on at whatever the camera delivers.
        case missed
    }

    let requestedFrameRate: Double
    let expectedFrameRate: Double
    let outcome: Outcome

    /// When the rate was asked for, on the host clock.
    let requestedAt: MonotonicTimestamp
    /// When the restart was done, if there was one.
    let restartedAt: MonotonicTimestamp?
    /// The capture time of the first frame at the rate; nil if it never came.
    let arrivedAt: MonotonicTimestamp?

    /// From asking to the first frame at the rate.
    var delay: TimeInterval? {
        arrivedAt.map { $0.seconds - requestedAt.seconds }
    }
}

/// Exposure, focus and white balance as they were held in a precision window.
nonisolated struct CaptureSettings: Equatable, Codable, Sendable {
    /// The exposure time in effect when they were locked, in seconds.
    let exposureDuration: TimeInterval
    let iso: Double
    /// The longest exposure auto exposure was allowed in the window
    /// (`CaptureSettingsPolicy.maximumExposureShare`); nil if not capped.
    let maximumExposureDuration: TimeInterval?

    let isExposureLocked: Bool
    let isFocusLocked: Bool
    let isWhiteBalanceLocked: Bool

    /// False if they were still adjusting when the wait for them to settle
    /// ran out (`PrecisionWindowMonitor.settleTimeout`) and were locked as they were.
    let hadSettled: Bool
}

/// What the frames of a precision window delivered, from when the rate was
/// decided (its arrival, or when it was given up) up to when this was asked.
nonisolated struct PrecisionRateDelivery: Equatable, Codable, Sendable {
    let requestedFrameRate: Double
    /// From the capture times of the frames that arrived; nil for fewer than two.
    let deliveredFrameRate: Double?
    let frames: Int
    let dropped: Int
    let longestGap: TimeInterval

    /// The exposure times and ISO values the frames carried, if they said.
    let exposureDurations: ClosedRange<Double>?
    let isoValues: ClosedRange<Double>?

    /// A rate this far below the one asked for counts as not reached. The
    /// precision windows measured on the device delivered 99 % and more
    /// when the rate arrived (119.95 of 120, 237.9 and 236.9 of 240) and
    /// 12.5 % when it did not (15 of 120).
    static let reachedShare = 0.9

    var isReached: Bool {
        guard let deliveredFrameRate else { return false }
        return deliveredFrameRate >= requestedFrameRate * Self.reachedShare
    }
}

/// What the camera tells a start about itself.
nonisolated enum CameraReport: Equatable, Codable, Sendable {
    /// Frames arrive (again).
    case delivering

    /// Frames stopped. `lastFrame` is the capture time of the last one
    /// that arrived before.
    case failed(CameraFault, lastFrame: MonotonicTimestamp?)

    /// The camera as a start found it before its first command.
    case prepared(CameraSetup)

    /// The precision rate arrived, after a restart or not at all.
    case precisionRate(PrecisionRateReport)

    /// The running session was stopped and started again at the precision
    /// rate, because the rate did not arrive (`PrecisionWindowMonitor.arrivalDeadline`).
    case restarted

    /// Exposure, focus and white balance are held for the precision window.
    case settingsLocked(CaptureSettings)

    /// What the precision window delivered up to the end of the run.
    case delivered(PrecisionRateDelivery)
}

/// What the result of a start has to say about the camera.
nonisolated extension StartSession {
    /// What the precision window delivered, if it fell short of the rate
    /// asked for: the movement times are then less precise than they could be.
    var precisionShortfall: PrecisionRateDelivery? {
        events.lazy
            .compactMap { if case .camera(.delivered(let delivery)) = $0.kind { delivery } else { nil } }
            .last
            .flatMap { $0.isReached ? nil : $0 }
    }

    /// Whether the camera failed once the gun was out. The start went on;
    /// athletes who moved after that have no result.
    var cameraFailedAfterTheGun: Bool {
        guard let gun = events.firstIndex(where: { $0.kind == .gunCommitted }) else { return false }

        return events[gun...].contains {
            if case .camera(.failed) = $0.kind { true } else { false }
        }
    }
}
