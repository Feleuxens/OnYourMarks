//
//  FrameStatistics.swift
//  OnYourMarks
//

import CoreVideo
import Foundation

/// One video frame and when it was captured.
nonisolated struct CameraFrame: @unchecked Sendable {
    /// Only read by consumers, never modified.
    let pixelBuffer: CVPixelBuffer

    /// The frame's capture timestamp on the host clock, the same clock
    /// the audio schedule uses.
    let timestamp: MonotonicTimestamp

    /// Counts delivered frames since the camera was configured.
    let index: Int
}

nonisolated enum FrameDropReason: Sendable {
    /// The previous frame was still being processed.
    case late
    case outOfBuffers
    case discontinuity
    case unknown
}

/// What happened to the frames of one stretch of capture.
nonisolated struct FrameStatistics: Equatable, Sendable {
    private(set) var delivered = 0
    private(set) var droppedLate = 0
    private(set) var droppedOutOfBuffers = 0
    private(set) var droppedDiscontinuity = 0
    private(set) var droppedUnknown = 0

    private(set) var firstTimestamp: TimeInterval?
    private(set) var lastTimestamp: TimeInterval?

    /// The longest time between two delivered frames.
    private(set) var longestGap: TimeInterval = 0

    /// The exposure times and ISO values of the frames that said, from
    /// their metadata: what was in effect, not what was asked for.
    private(set) var exposureDurations: ClosedRange<Double>?
    private(set) var isoValues: ClosedRange<Double>?

    var dropped: Int {
        droppedLate + droppedOutOfBuffers + droppedDiscontinuity + droppedUnknown
    }

    /// Rate of the delivered frames, from their capture timestamps.
    var deliveredFrameRate: Double? {
        guard delivered > 1, let firstTimestamp, let lastTimestamp, lastTimestamp > firstTimestamp else {
            return nil
        }
        return Double(delivered - 1) / (lastTimestamp - firstTimestamp)
    }

    mutating func recordDelivered(at timestamp: TimeInterval, exposure: TimeInterval? = nil, iso: Double? = nil) {
        if let lastTimestamp {
            longestGap = max(longestGap, timestamp - lastTimestamp)
        } else {
            firstTimestamp = timestamp
        }

        lastTimestamp = timestamp
        delivered += 1

        if let exposure {
            exposureDurations = Self.widen(exposureDurations, by: exposure)
        }
        if let iso {
            isoValues = Self.widen(isoValues, by: iso)
        }
    }

    private static func widen(_ range: ClosedRange<Double>?, by value: Double) -> ClosedRange<Double> {
        guard let range else { return value...value }
        return min(range.lowerBound, value)...max(range.upperBound, value)
    }

    mutating func recordDropped(_ reason: FrameDropReason) {
        switch reason {
        case .late: droppedLate += 1
        case .outOfBuffers: droppedOutOfBuffers += 1
        case .discontinuity: droppedDiscontinuity += 1
        case .unknown: droppedUnknown += 1
        }
    }
}
