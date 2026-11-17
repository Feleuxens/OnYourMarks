//
//  RecordedVideoReader.swift
//  OnYourMarks
//

import AVFoundation

/// Reads a recorded start's video back, frame by frame, each frame with its
/// capture time.
nonisolated enum RecordedVideoReader {
    struct Summary: Equatable, Sendable {
        /// Frames the video holds.
        var decoded = 0

        /// Frames whose place in the video matches no stored capture time.
        var unmatched = 0
    }

    enum ReadError: Error {
        case noVideoTrack
    }

    /// The pixel format the frames are decoded to: the camera's, so that a
    /// decoded frame is sampled and given to pose detection like a live one.
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    /// Decodes every frame in the order shown and hands it to `body` with the
    /// capture time stored for its place in the video (`VideoTimeline`):
    /// the time the live analysis gave the same frame. The buffer lies on
    /// its side like the camera's and is only valid inside `body`.
    ///
    /// A frame whose place matches no stored time exactly is counted and
    /// passed over: then the video and its frame times disagree, and no
    /// nearest time may stand in for the frame's own.
    ///
    /// Throws `CancellationError` between two frames once the task is cancelled.
    static func read(
        _ url: URL,
        frameTimes: [MonotonicTimestamp],
        _ body: (CVPixelBuffer, MonotonicTimestamp) throws -> Void
    ) async throws -> Summary {
        let asset = AVURLAsset(url: url)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReadError.noVideoTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        )

        let provider = reader.outputProvider(for: output)
        try reader.start()

        var summary = Summary()
        guard let first = frameTimes.first else { return summary }

        let places = frameTimes.map { VideoTimeline.presentationTime(of: $0, first: first) }
        var next = 0

        while let sample = try await provider.next() {
            try Task.checkCancellation()
            summary.decoded += 1

            let place = sample.presentationTimeStamp
            while next < places.count, places[next] < place {
                next += 1
            }

            guard next < places.count, places[next] == place, case .pixelBuffer(let picture) = sample.content else {
                summary.unmatched += 1
                continue
            }

            try picture.withUnsafeBuffer { try body($0, frameTimes[next]) }
            next += 1
        }
        return summary
    }
}
