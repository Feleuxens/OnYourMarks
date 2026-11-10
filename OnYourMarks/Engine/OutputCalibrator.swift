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
        let windowSamples = samples(in: chunks, during: window)
        let noiseSamples = samples(in: chunks, during: noiseWindow)

        guard !windowSamples.isEmpty, !noiseSamples.isEmpty else { return nil }

        let peak = windowSamples.map { abs($0.value) }.max() ?? 0
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
                return windowSamples[index].time
            }
        }
        return nil
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

/// Records the built-in microphone on its own engine, so the playback
/// engine and its graph stay exactly as they are for starts.
@MainActor
final class MicrophoneRecorder {
    /// Filled on the audio thread, read on the main actor.
    private final class ChunkStore: Sendable {
        let chunks = Mutex<[RecordedChunk]>([])
    }
    
    private let engine = AVAudioEngine()
    private let store = ChunkStore()

    /// Time from sound reaching the microphone to the sample's timestamp.
    private(set) var inputLatency: TimeInterval = 0

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
        
        // The non-deprecated, throwing form. The SDK ships no Swift wrapper for
        // it yet, so it's imported with a placeholder for the error argument.
        // A nil format records in whatever format the hardware delivers, which
        // can differ from the node's format while Bluetooth plays.
        try input.__installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil,
            error: (),
            block: Self.tapBlock(appendingTo: store)
        )
        
        engine.prepare()
        try engine.start()
    }
    
    /// Built outside the main actor: the tap runs on an audio thread, and a
    /// closure written in this class would be checked for main-actor isolation.
    private nonisolated static func tapBlock(appendingTo store: ChunkStore) -> AVAudioNodeTapBlock {
        { buffer, time in
            guard time.isHostTimeValid, let channel = buffer.floatChannelData?[0] else { return }
            
            let chunk = RecordedChunk(
                hostSeconds: AVAudioTime.seconds(forHostTime: time.hostTime),
                sampleRate: buffer.format.sampleRate,
                samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            )
            store.chunks.withLock { $0.append(chunk) }
        }
    }
    
    /// Whether the microphone delivers audio yet, i.e. the hardware has
    /// finished reconfiguring for recording.
    var isReceivingAudio: Bool {
        store.chunks.withLock { !$0.isEmpty }
    }
    
    /// Stops recording and returns what was captured.
    func stop() -> [RecordedChunk] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return store.chunks.withLock { $0 }
    }
}
