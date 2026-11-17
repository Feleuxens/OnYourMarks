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

    /// The recording the second pass is working on.
    private(set) var analysing: UUID?

    /// The second passes that are loaded, by recording.
    private(set) var analyses: [UUID: RecordingAnalysis] = [:]

    @ObservationIgnored private let source: FrameSource
    @ObservationIgnored private let store: RecordingStore
    @ObservationIgnored private let analyser: (any RecordingAnalyser)?

    @ObservationIgnored private var capture: Capture?
    @ObservationIgnored private var tailTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
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

    /// - Parameter analyser: runs the second pass over each kept recording;
    ///   nil for none.
    init(
        source: FrameSource,
        store: RecordingStore = RecordingStore(),
        analyser: (any RecordingAnalyser)? = SecondPassAnalyser()
    ) {
        self.source = source
        self.store = store
        self.analyser = analyser

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

        // The new start needs the phone; the review can run the pass again.
        cancelAnalysis()

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
        analyse(recording)
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

    // MARK: - Second pass

    /// What the second pass found in a recording, once it is loaded.
    func analysis(of recording: StartRecording) -> RecordingAnalysis? {
        analyses[recording.id]
    }

    /// Loads the second pass over a recording from its folder. A recording
    /// whose pass never finished, e.g. because the next start began, is
    /// analysed now, unless a start is being recorded.
    func loadAnalysis(of recording: StartRecording) async {
        guard analyses[recording.id] == nil else { return }

        if let stored = await Self.loadAnalysis(of: recording.id, in: location(of: recording), from: store) {
            analyses[recording.id] = stored
            return
        }

        if capture == nil, analysing == nil {
            analyse(recording)
        }
    }

    /// Runs the second pass at low priority, off the main actor. Only one
    /// runs at a time; the newest recording goes first.
    private func analyse(_ recording: StartRecording) {
        guard let analyser else { return }

        cancelAnalysis()
        analysing = recording.id

        let id = recording.id
        let directory = store.directory(of: id, in: location(of: recording))

        analysisTask = Task(priority: .background) { [weak self] in
            let analysis = await Self.run(analyser, on: directory)

            // A cancelled pass leaves the state to whoever cancelled it.
            guard let self, !Task.isCancelled else { return }

            analysisTask = nil
            analysing = nil

            guard let analysis else { return }

            analyses[id] = analysis
            logger.info(
                """
                Second pass: \(analysis.frames.decoded) frames, \(analysis.frames.withPose) with a pose, \
                \(analysis.duration, format: .fixed(precision: 1)) s
                """
            )

            // Wherever the recording is by now; not at all if it was deleted.
            guard let recording = last?.id == id ? last : saved.first(where: { $0.id == id }) else { return }
            await Self.write(analysis, in: location(of: recording), to: store)
        }
    }

    private func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysing = nil
    }

    @concurrent
    private nonisolated static func run(_ analyser: any RecordingAnalyser, on directory: URL) async -> RecordingAnalysis? {
        do {
            return try await analyser.analyse(RecordedStart.load(from: directory))
        } catch is CancellationError {
            return nil
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks", category: "Recording")
                .error("The second pass failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @concurrent
    private nonisolated static func write(
        _ analysis: RecordingAnalysis,
        in location: RecordingStore.Location,
        to store: RecordingStore
    ) async {
        _ = try? store.write(analysis, in: location)
    }

    @concurrent
    private nonisolated static func loadAnalysis(
        of id: UUID,
        in location: RecordingStore.Location,
        from store: RecordingStore
    ) async -> RecordingAnalysis? {
        store.analysis(of: id, in: location)
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
        if analysing == recording.id {
            cancelAnalysis()
        }
        analyses[recording.id] = nil
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
