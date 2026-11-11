//
//  VideoFileWriter.swift
//  OnYourMarks
//

import AVFoundation
import OSLog
import Synchronization

/// How capture times on the host clock map to times in a recorded video.
nonisolated enum VideoTimeline {
    /// Microseconds: far finer than the 4 ms between frames at 240 fps. The
    /// video's track uses the same scale, so a seek computed from a stored
    /// capture time lands on its frame exactly.
    static let timescale: CMTimeScale = 1_000_000

    /// Where a frame sits in the video: its capture time since the first frame's.
    static func presentationTime(of time: MonotonicTimestamp, first: MonotonicTimestamp) -> CMTime {
        CMTime(seconds: time.seconds - first.seconds, preferredTimescale: timescale)
    }
}

/// Writes the camera's frames to a movie file as they arrive, each at its
/// capture time. The frame rate may change on the way (idle to precision
/// and back); the video keeps every frame's real distance to the next.
///
/// One writer per recording.
nonisolated final class VideoFileWriter: Sendable {
    struct Summary: Equatable, Sendable {
        /// Capture time of every frame in the file, in order.
        var frameTimes: [MonotonicTimestamp] = []
        /// Frames the encoder was not ready for.
        var skippedFrames = 0
        var failure: String?
    }

    /// Enough for 1080p with fast movement; the Camera app uses about this
    /// much for 1080p HEVC at 60 fps.
    static let averageBitRate = 24_000_000

    /// A key frame every 30 frames, a quarter second at 120 fps, so that
    /// stepping backwards never has to decode far.
    static let maximumKeyFrameInterval = 30

    private struct State {
        var writer: AVAssetWriter?
        var receiver: AVAssetWriterInput.PixelBufferReceiver?
        var isFinishing = false
        var summary = Summary()
    }

    private let url: URL
    private let state = Mutex(State())

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks",
        category: "Recording"
    )

    /// - Parameter url: where the movie goes; nothing may be there yet.
    init(url: URL) {
        self.url = url
    }

    /// Called on the capture queue. Hands the buffer to the encoder, which
    /// holds it only until it is encoded.
    func append(_ frame: CameraFrame) {
        let url = self.url

        let failure: String? = state.withLock { state in
            guard !state.isFinishing, state.summary.failure == nil else { return nil }

            do {
                if state.writer == nil {
                    try Self.open(&state, at: url, for: frame)
                }
            } catch {
                state.summary.failure = error.localizedDescription
                return state.summary.failure
            }

            guard let receiver = state.receiver else { return nil }

            // Times in the file must rise; the camera's do.
            let first = state.summary.frameTimes.first ?? frame.timestamp
            if let last = state.summary.frameTimes.last, frame.timestamp <= last { return nil }

            let time = VideoTimeline.presentationTime(of: frame.timestamp, first: first)

            // The encoder only reads the buffer, like every consumer of a frame.
            nonisolated(unsafe) let pixelBuffer = frame.pixelBuffer

            do {
                // Never wait for the encoder: the analysis runs on this queue.
                guard try receiver.appendImmediately(CVReadOnlyPixelBuffer(unsafeBuffer: pixelBuffer), with: time) else {
                    state.summary.skippedFrames += 1
                    return nil
                }
            } catch {
                state.summary.failure = error.localizedDescription
                return state.summary.failure
            }

            state.summary.frameTimes.append(frame.timestamp)
            return nil
        }

        if let failure {
            logger.error("Video recording failed: \(failure, privacy: .public)")
        }
    }

    /// Closes the file. The completion is called once, on any thread, when
    /// the file is complete or has failed.
    func finish(_ completion: @escaping @Sendable (Summary) -> Void) {
        let isClosing = state.withLock { state in
            guard !state.isFinishing else { return false }
            state.isFinishing = true

            guard let writer = state.writer, writer.status == .writing else { return false }

            state.receiver?.finish()
            writer.finishWriting { [self] in
                completion(conclude())
            }
            return true
        }

        if !isClosing {
            completion(conclude())
        }
    }

    private func conclude() -> Summary {
        state.withLock { state in
            if let writer = state.writer, writer.status != .completed, state.summary.failure == nil {
                state.summary.failure = writer.error?.localizedDescription ?? "the file was not completed"
            }

            state.writer = nil
            state.receiver = nil
            return state.summary
        }
    }

    /// Sets the file up for frames like the given one, the first of the recording.
    private static func open(_ state: inout State, at url: URL, for frame: CameraFrame) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: CVPixelBufferGetWidth(frame.pixelBuffer),
                AVVideoHeightKey: CVPixelBufferGetHeight(frame.pixelBuffer),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: averageBitRate,
                    AVVideoMaxKeyFrameIntervalKey: maximumKeyFrameInterval,
                    // Frames are stored in the order they are shown, so
                    // every frame can be reached by stepping.
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ]
        )
        input.mediaTimeScale = VideoTimeline.timescale
        // The camera's buffers lie on their side; players turn the picture
        // upright, the way Vision and the preview see it.
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)

        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)

        try writer.start()
        writer.startSession(atSourceTime: .zero)

        state.writer = writer
        state.receiver = receiver
    }
}
