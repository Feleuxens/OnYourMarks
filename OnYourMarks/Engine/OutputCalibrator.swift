//
//  OutputCalibrator.swift
//  OnYourMarks
//

import AVFAudio
import OSLog
import Synchronization

nonisolated enum CalibrationError: LocalizedError {
    case recordingFailed(String)
    case playbackFailed(String)
    case outputChanged
    case tooFewClicksHeard(heard: Int, needed: Int)
    /// Every click's offset from the prediction, for diagnosis.
    case inconsistentClicks(offsets: [TimeInterval])

    var errorDescription: String? {
        switch self {
        case .outputChanged:
            String(localized: "The audio output changed during the calibration. Please try again.")
        case .playbackFailed(let reason):
            String(localized: "The calibration click could not be played: \(reason)")
        case .recordingFailed(let reason):
            String(localized: "The microphone could not record: \(reason)")
        case .tooFewClicksHeard(let heard, let needed):
            String(localized: "The microphone only heard \(heard) of \(needed) needed clicks. Turn the volume up and hold the output close to the iPhone.")
        case .inconsistentClicks(let offsets):
            String(localized: "The clicks varied by \(Int(((offsets.max() ?? 0) - (offsets.min() ?? 0)) * 1000)) ms. Keep the output still and the room quiet, then try again.")
        }
    }
}

/// One stretch of microphone samples and when its first sample was captured.
nonisolated struct RecordedChunk: Sendable {
    let hostSeconds: TimeInterval
    let sampleRate: Double
    let samples: [Float]
}

/// The pure part of a calibration: finding clicks in a recording and
/// summarizing them. Kept free of audio hardware so it can be tested.
nonisolated enum CalibrationMath {
    static let clickCount = 6
    static let minimumClicksHeard = 4
    
    /// Played first and not measured: many Bluetooth speakers save power
    /// while idle and delay or cut the first sound after the stream starts,
    /// and the output can still settle right after the microphone started.
    static let warmUpClicks = 2

    /// More spread than this means the measurements can't be trusted.
    static let maximumSpread: TimeInterval = 0.030

    /// Added to the observed spread for the microphone's own timing error.
    static let measurementMargin: TimeInterval = 0.001

    /// Same relative threshold as the onset in the sound file, so both
    /// mark the same point of the attack.
    static let relativeThreshold: Float = 0.1

    /// Required ratio between the click and the background noise.
    static let minimumSignalToNoise: Float = 8
    
    /// The gun stays near full level for about 280 ms. A crossing only counts
    /// as its onset if the signal stays loud this long, so a short noise spike
    /// can't be taken for the click.
    static let sustainDuration: TimeInterval = 0.010

    /// When the first sample at or above the click's threshold was captured,
    /// searching `window` and measuring background noise in `noiseWindow`.
    static func onset(
        in chunks: [RecordedChunk],
        window: ClosedRange<TimeInterval>,
        noiseWindow: ClosedRange<TimeInterval>
    ) -> TimeInterval? {
        detectOnset(in: chunks, window: window, noiseWindow: noiseWindow)?.time
    }

    /// An onset, and how clearly it stood out from the noise before it.
    struct DetectedOnset: Equatable, Sendable {
        /// The sample's timestamp.
        let time: TimeInterval
        let sampleRate: Double

        /// Peak magnitude in the window, RMS of the noise.
        let peak: Float
        let noise: Float
    }

    /// Like `onset`, with what it was found against.
    static func detectOnset(
        in chunks: [RecordedChunk],
        window: ClosedRange<TimeInterval>,
        noiseWindow: ClosedRange<TimeInterval>
    ) -> DetectedOnset? {
        // Across a gap the attack may be missing, and its loud tail would
        // pass for the onset: the search ends at the first one. The peak
        // comes from everything the window holds, so a quiet sound before
        // a gap is not measured against itself.
        guard let covered = gaplessCoverage(of: window, in: chunks) else { return nil }

        let windowSamples = samples(in: chunks, during: covered)
        let noiseSamples = samples(in: chunks, during: noiseWindow)

        guard !windowSamples.isEmpty, !noiseSamples.isEmpty else { return nil }

        let peak = samples(in: chunks, during: window).map { abs($0.value) }.max() ?? 0
        let noise = rms(noiseSamples.map(\.value))

        guard peak > 0, peak >= noise * minimumSignalToNoise else { return nil }

        let threshold = max(peak * relativeThreshold, noise * minimumSignalToNoise / 2)
        
        let sampleRate = chunks.first?.sampleRate ?? 0
        let sustainCount = max(1, Int(sustainDuration * sampleRate))
        
        // Running sums of the magnitude, for the mean over any stretch.
        var sums = [Float](repeating: 0, count: windowSamples.count + 1)
        for (index, sample) in windowSamples.enumerated() {
            sums[index + 1] = sums[index] + abs(sample.value)
        }
        
        for index in windowSamples.indices where abs(windowSamples[index].value) >= threshold {
            let end = min(index + sustainCount, windowSamples.count)
            let mean = (sums[end] - sums[index]) / Float(end - index)
            
            if end - index == sustainCount, mean >= threshold {
                return DetectedOnset(time: windowSamples[index].time, sampleRate: sampleRate, peak: peak, noise: noise)
            }
        }
        return nil
    }

    /// Whether the recording holds any sample in the stretch.
    static func covers(_ chunks: [RecordedChunk], _ range: ClosedRange<TimeInterval>) -> Bool {
        chunks.contains { $0.end > range.lowerBound && $0.hostSeconds <= range.upperBound }
    }

    /// Larger steps between one chunk's end and the next chunk's start are
    /// a gap. A dropout loses at least one tap buffer, 1024 samples
    /// requested, 21 ms at 48 kHz; the timestamps of chunks that follow on
    /// differ far less. Reasoned: the jitter between chunks is not measured.
    static let maximumChunkGap: TimeInterval = 0.001

    /// The part of the stretch the recording holds without a gap, from its
    /// beginning on. Nil if the recording doesn't hold its beginning.
    static func gaplessCoverage(
        of range: ClosedRange<TimeInterval>,
        in chunks: [RecordedChunk]
    ) -> ClosedRange<TimeInterval>? {
        let overlapping = chunks
            .filter { $0.end > range.lowerBound && $0.hostSeconds <= range.upperBound }
            .sorted { $0.hostSeconds < $1.hostSeconds }

        guard let first = overlapping.first, first.hostSeconds <= range.lowerBound + maximumChunkGap else { return nil }

        var coveredUntil = first.end
        for chunk in overlapping.dropFirst() {
            guard chunk.hostSeconds <= coveredUntil + maximumChunkGap else { break }
            coveredUntil = max(coveredUntil, chunk.end)
        }
        return range.lowerBound ... min(range.upperBound, coveredUntil)
    }

    /// Median of the per-click offsets, and how far the clicks strayed from it.
    static func summarize(offsets: [TimeInterval]) throws -> (correction: TimeInterval, uncertainty: TimeInterval) {
        guard offsets.count >= minimumClicksHeard else {
            throw CalibrationError.tooFewClicksHeard(heard: offsets.count, needed: minimumClicksHeard)
        }

        let sorted = offsets.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]

        let spread = (sorted.last ?? 0) - (sorted.first ?? 0)

        guard spread <= maximumSpread else {
            throw CalibrationError.inconsistentClicks(offsets: offsets)
        }

        let largestDeviation = sorted.map { abs($0 - median) }.max() ?? 0

        return (median, largestDeviation + measurementMargin)
    }

    private static func samples(
        in chunks: [RecordedChunk],
        during range: ClosedRange<TimeInterval>
    ) -> [(time: TimeInterval, value: Float)] {
        var result: [(time: TimeInterval, value: Float)] = []

        for chunk in chunks {
            let end = chunk.hostSeconds + Double(chunk.samples.count) / chunk.sampleRate
            guard end >= range.lowerBound, chunk.hostSeconds <= range.upperBound else { continue }

            for (index, value) in chunk.samples.enumerated() {
                let time = chunk.hostSeconds + Double(index) / chunk.sampleRate
                if range.contains(time) {
                    result.append((time, value))
                }
            }
        }
        return result
    }

    private static func rms(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return (values.reduce(0) { $0 + $1 * $1 } / Float(values.count)).squareRoot()
    }
}

/// Chunks of audio a tap delivers, filled on the audio thread and read on
/// the main actor.
nonisolated final class RecordedChunkStore: Sendable {
    private let chunks = Mutex<[RecordedChunk]>([])

    /// How much audio is kept, counted back from the newest chunk's end;
    /// nil keeps everything.
    let retention: TimeInterval?

    init(retention: TimeInterval? = nil) {
        self.retention = retention
    }

    func append(_ chunk: RecordedChunk) {
        chunks.withLock { chunks in
            chunks.append(chunk)

            guard let retention else { return }
            let keepFrom = chunk.end - retention
            if let first = chunks.firstIndex(where: { $0.end > keepFrom }), first > 0 {
                chunks.removeFirst(first)
            }
        }
    }

    var recorded: [RecordedChunk] {
        chunks.withLock { $0 }
    }

    var isEmpty: Bool {
        chunks.withLock { $0.isEmpty }
    }

    /// Timestamp just after the newest sample.
    var coveredUntil: TimeInterval? {
        chunks.withLock { $0.last?.end }
    }

    /// Built outside the main actor: the tap runs on an audio thread, and a
    /// closure written in a main-actor class would be checked for its isolation.
    func tapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, time in
            guard time.isHostTimeValid, let channel = buffer.floatChannelData?[0] else { return }

            append(
                RecordedChunk(
                    hostSeconds: AVAudioTime.seconds(forHostTime: time.hostTime),
                    sampleRate: buffer.format.sampleRate,
                    samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                )
            )
        }
    }
}

nonisolated extension RecordedChunk {
    /// Timestamp just after the chunk's last sample.
    var end: TimeInterval {
        hostSeconds + Double(samples.count) / sampleRate
    }
}

/// Records the built-in microphone on its own engine, so the playback
/// engine and its graph stay exactly as they are for starts.
final class MicrophoneRecorder {
    private let engine = AVAudioEngine()
    private let store: RecordedChunkStore

    /// Time from sound reaching the microphone to the sample's timestamp.
    private(set) var inputLatency: TimeInterval = 0

    private(set) var sampleRate: Double = 0

    private(set) var isRecording = false

    /// False once a reconfiguration of the hardware has stopped it.
    var isRunning: Bool {
        isRecording && engine.isRunning
    }

    /// - Parameter retention: how many seconds of the newest audio are
    ///   kept; nil keeps all of it.
    init(retention: TimeInterval? = nil) {
        store = RecordedChunkStore(retention: retention)
    }

    func start() throws {
        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            let session = AVAudioSession.sharedInstance()
            let inputs = session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
            throw CalibrationError.recordingFailed(
                "no input available (category \(session.category.rawValue), inputs: \(inputs.isEmpty ? "none" : inputs))"
            )
        }
        
        let nodeLatency = input.presentationLatency
        inputLatency = nodeLatency > 0 ? nodeLatency : AVAudioSession.sharedInstance().inputLatency
        sampleRate = hardwareFormat.sampleRate
        
        // The non-deprecated, throwing form. The SDK ships no Swift wrapper for
        // it yet, so it's imported with a placeholder for the error argument.
        // A nil format records in whatever format the hardware delivers, which
        // can differ from the node's format while Bluetooth plays.
        try input.__installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil,
            error: (),
            block: store.tapBlock()
        )

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRecording = true
    }

    /// Whether the microphone delivers audio yet, i.e. the hardware has
    /// finished reconfiguring for recording.
    var isReceivingAudio: Bool {
        !store.isEmpty
    }

    /// Timestamp just after the newest sample delivered so far.
    var coveredUntil: TimeInterval? {
        store.coveredUntil
    }

    /// What has been captured so far, while recording goes on.
    var recorded: [RecordedChunk] {
        store.recorded
    }

    /// Stops recording and returns what was captured.
    func stop() -> [RecordedChunk] {
        if isRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRecording = false
        }
        return store.recorded
    }
}
