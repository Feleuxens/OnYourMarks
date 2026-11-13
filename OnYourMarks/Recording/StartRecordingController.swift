//
//  StartRecordingController.swift
//  OnYourMarks
//

import Foundation
import OSLog

/// Records each start for the review: the camera's frames into a video,
/// the tracking data and the start's record beside it. Keeps the last start
/// until the next one replaces it, and the library of saved ones.
@Observable
final class StartRecordingController: StartRecorder {
    /// The last recorded start. Temporary: the next one replaces it.
    private(set) var last: StartRecording?

    /// The saved starts, newest first.
    private(set) var saved: [StartRecording] = []

    /// Whether a recording's files are still being written.
    var isFinishing: Bool {
        finishing > 0
    }

    @ObservationIgnored private let source: FrameSource
    @ObservationIgnored private let store: RecordingStore

    @ObservationIgnored private var capture: Capture?
    @ObservationIgnored private var tailTask: Task<Void, Never>?
    private var finishing = 0

    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks",
        category: "Recording"
    )

    /// One recording in progress.
    private nonisolated struct Capture: Sendable {
        let id: UUID
        let date: Date
        let writer: VideoFileWriter
        var tracking: [TrackingFrame] = []
        var motion: [MotionRecord] = []
        var session: StartSession?
        var results: [AthleteStartResult] = []

        /// Only a start that got as far as a gun or a false start is worth
        /// replacing the last one for.
        var isKept: Bool {
            session?.outcome == .completed || session?.outcome == .falseStart
        }
    }

    init(source: FrameSource, store: RecordingStore = RecordingStore()) {
        self.source = source
        self.store = store

        last = store.recordings(in: .temporary).first
        saved = store.recordings(in: .library)

        // What a start left behind that never finished, e.g. when the app
        // was closed. Only here, before anything records: a sweep beside a
        // recording in progress could take its folder.
        store.keepOnly(Set(last.map { [$0.id] } ?? []))
    }

    // MARK: - Recording

    func beginRecording() -> Bool {
        // A start right after another: the earlier one's tail ends here.
        flush()

        guard source.isDelivering else { return false }

        let id = UUID()

        do {
            let writer = VideoFileWriter(url: try store.prepare(id))

            capture = Capture(id: id, date: .now, writer: writer)
            source.setRecordingHandler(Self.frameHandler(for: writer))
            return true
        } catch {
            logger.error("Could not prepare the recording: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func record(_ frame: TrackingFrame) {
        capture?.tracking.append(frame)
    }

    func record(_ motion: MotionRecord) {
        capture?.motion.append(motion)
    }

    func endRecording(session: StartSession, results: [AthleteStartResult], tail: TimeInterval) {
        guard capture != nil, capture?.session == nil else { return }

        capture?.session = session
        capture?.results = results

        guard session.outcome == .completed, tail > 0 else {
            conclude()
            return
        }

        tailTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(tail))

            guard !Task.isCancelled else { return }
            self?.conclude()
        }
    }

    /// Ends a recording that is still running on after its start, e.g.
    /// because the camera is about to stop.
    func flush() {
        guard capture?.session != nil else { return }

        conclude()
    }

    private func conclude() {
        tailTask?.cancel()
        tailTask = nil

        guard let capture else { return }
        self.capture = nil

        source.setRecordingHandler(nil)
        finishing += 1
        capture.writer.finish(Self.completion(for: self, capture: capture))
    }

    private func complete(_ capture: Capture, _ summary: VideoFileWriter.Summary) async {
        defer { finishing -= 1 }

        if let failure = summary.failure {
            logger.error("The recording failed: \(failure, privacy: .public)")
        }

        guard capture.isKept, summary.failure == nil, !summary.frameTimes.isEmpty, let session = capture.session else {
            store.delete(capture.id, in: .temporary)
            return
        }

        let recording = StartRecording(
            id: capture.id,
            date: capture.date,
            session: session,
            results: capture.results,
            frameTimes: summary.frameTimes,
            skippedFrames: summary.skippedFrames
        )

        do {
            // Files are closed in no fixed order: a start right after this
            // one may be complete already, and then it stays the last.
            guard !isSuperseded(recording) else {
                store.delete(capture.id, in: .temporary)
                return
            }

            try await Self.write(recording, capture: capture, in: store)
        } catch {
            logger.error("Could not store the recording: \(error.localizedDescription, privacy: .public)")
            store.delete(capture.id, in: .temporary)
            return
        }

        guard !isSuperseded(recording) else {
            store.delete(capture.id, in: .temporary)
            return
        }

        if let replaced = last {
            store.delete(replaced.id, in: .temporary)
        }

        logger.info(
            """
            Recorded \(summary.frameTimes.count) frames, \(summary.skippedFrames) skipped, \
            \(capture.tracking.count) tracking frames
            """
        )

        last = recording
    }

    private func isSuperseded(_ recording: StartRecording) -> Bool {
        last.map { $0.date > recording.date } ?? false
    }

    @concurrent
    private nonisolated static func write(
        _ recording: StartRecording,
        capture: Capture,
        in store: RecordingStore
    ) async throws {
        try store.write(recording, tracking: capture.tracking, motion: capture.motion)
    }

    /// Built outside the main actor: the camera calls it on the capture queue.
    private nonisolated static func frameHandler(for writer: VideoFileWriter) -> @Sendable (CameraFrame) -> Void {
        { writer.append($0) }
    }

    /// Built outside the main actor: the video writer calls it on a queue of its own.
    private nonisolated static func completion(
        for controller: StartRecordingController,
        capture: Capture
    ) -> @Sendable (VideoFileWriter.Summary) -> Void {
        { [weak controller] summary in
            Task { @MainActor in
                await controller?.complete(capture, summary)
            }
        }
    }

    // MARK: - Library

    func isSaved(_ recording: StartRecording) -> Bool {
        saved.contains { $0.id == recording.id }
    }

    func videoURL(of recording: StartRecording) -> URL {
        store.videoURL(of: recording.id, in: location(of: recording))
    }

    /// The video, the start's record, the tracking data and what the
    /// sampler saw, for sharing.
    func files(of recording: StartRecording) -> [URL] {
        store.files(of: recording.id, in: location(of: recording))
    }

    func tracking(of recording: StartRecording) async -> [TrackingFrame] {
        await Self.loadTracking(of: recording.id, in: location(of: recording), from: store)
    }

    /// Moves the last start into the library, where the next start leaves it alone.
    func save(_ recording: StartRecording) throws {
        guard !isSaved(recording) else { return }

        try store.save(recording.id)
        saved.insert(recording, at: 0)

        if last?.id == recording.id {
            last = nil
        }
    }

    func delete(_ recording: StartRecording) {
        store.delete(recording.id, in: location(of: recording))

        saved.removeAll { $0.id == recording.id }
        if last?.id == recording.id {
            last = nil
        }
    }

    private func location(of recording: StartRecording) -> RecordingStore.Location {
        isSaved(recording) ? .library : .temporary
    }

    @concurrent
    private nonisolated static func loadTracking(
        of id: UUID,
        in location: RecordingStore.Location,
        from store: RecordingStore
    ) async -> [TrackingFrame] {
        (try? store.tracking(of: id, in: location)) ?? []
    }
}
