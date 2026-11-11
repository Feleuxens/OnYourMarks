//
//  ReviewModel.swift
//  OnYourMarks
//

import AVFoundation
import SwiftUI

/// Drives the review of one recorded start: which frame is on screen, and
/// the player that shows it.
@Observable
final class ReviewModel {
    /// How fast the video can be played; a start is over in a moment.
    static let rates: [Float] = [1, 0.25, 0.1]

    /// How often the frame counter follows the player while it plays.
    private static let playbackUpdateInterval = CMTime(value: 1, timescale: 60)

    let recording: StartRecording
    let player: AVPlayer

    private(set) var timeline: ReplayTimeline
    private(set) var currentFrame = 0
    private(set) var isPlaying = false

    /// Width of the upright picture divided by its height.
    private(set) var aspectRatio: CGFloat = 9.0 / 16.0

    var rate: Float = ReviewModel.rates[1] {
        didSet {
            if isPlaying { player.rate = rate }
        }
    }

    /// Drawn to stand out; nil shows every athlete alike.
    var highlighted: AthleteID?

    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?

    init(recording: StartRecording, videoURL: URL) {
        self.recording = recording
        timeline = ReplayTimeline(recording: recording, tracking: [])

        player = AVPlayer(url: videoURL)
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: Self.playbackUpdateInterval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.playbackAdvanced(to: time)
            }
        }
    }

    isolated deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    /// Takes in what is loaded after the screen appears.
    func load(tracking: [TrackingFrame]) async {
        timeline = ReplayTimeline(recording: recording, tracking: tracking)

        guard let asset = player.currentItem?.asset,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else {
            return
        }

        let upright = CGRect(origin: .zero, size: size).applying(transform)
        if upright.height > 0 {
            aspectRatio = abs(upright.width / upright.height)
        }
    }

    var tracking: TrackingFrame? {
        timeline.tracking(forFrame: currentFrame)
    }

    /// Where the current frame lies along the video, from 0 to 1.
    var progress: Double {
        guard timeline.frameTimes.indices.contains(currentFrame) else { return 0 }
        return timeline.fraction(of: timeline.frameTimes[currentFrame])
    }

    // MARK: - Moving through the video

    func step(by frames: Int) {
        show(frame: currentFrame + frames)
    }

    func scrub(toFraction fraction: Double) {
        show(frame: timeline.frame(atFraction: fraction))
    }

    /// Shows the frame that was on screen at a moment of the start.
    func jump(to time: MonotonicTimestamp) {
        show(frame: timeline.frame(at: time))
    }

    func show(frame: Int) {
        pause()
        currentFrame = frame.clamped(to: 0...max(0, timeline.frameCount - 1))

        // One seek at a time; while it runs, only the newest wish waits.
        guard seekTask == nil else { return }

        seekTask = Task { [weak self] in
            var shown: Int?

            while let self, shown != currentFrame {
                let target = currentFrame
                await player.seek(to: timeline.videoTime(ofFrame: target), toleranceBefore: .zero, toleranceAfter: .zero)
                shown = target
            }
            self?.seekTask = nil
        }
    }

    func togglePlayback() {
        if isPlaying {
            pause()
            return
        }

        if currentFrame >= timeline.frameCount - 1 {
            currentFrame = 0
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        isPlaying = true
        player.rate = rate
    }

    func pause() {
        guard isPlaying else { return }

        isPlaying = false
        player.pause()
    }

    private func playbackAdvanced(to time: CMTime) {
        guard isPlaying else { return }

        currentFrame = timeline.frame(atVideoTime: time.seconds)

        // The player stops by itself at the end.
        if player.timeControlStatus == .paused {
            isPlaying = false
        }
    }
}
