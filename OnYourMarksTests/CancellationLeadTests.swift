//
//  CancellationLeadTests.swift
//  OnYourMarksTests
//

import Testing
import AVFAudio
import Foundation
import QuartzCore
@testable import OnYourMarks

struct CancellationLeadMathTests {
    private let sampleRate = 48_000.0

    /// Mixer output from 10 s to 11 s: silence, with `sound` seconds of a
    /// sound from `soundAt` on.
    private func mixerOutput(soundAt: TimeInterval?, sound: TimeInterval = 0.01, level: Float = 0.4) -> [RecordedChunk] {
        let count = Int(sampleRate)
        var samples = [Float](repeating: 0, count: count)

        if let soundAt {
            let first = Int(((soundAt - 10) * sampleRate).rounded())
            for index in first..<min(first + Int(sound * sampleRate), count) {
                samples[index] = level * (index.isMultiple(of: 2) ? 1 : -1)
            }
        }

        return stride(from: 0, to: count, by: 1024).map { offset in
            RecordedChunk(
                hostSeconds: 10 + Double(offset) / sampleRate,
                sampleRate: sampleRate,
                samples: Array(samples[offset..<min(offset + 1024, count)])
            )
        }
    }

    private func trial(_ lead: TimeInterval, rendered: TimeInterval = 0, heardRatio: Double? = nil) -> CancellationTrial {
        CancellationTrial(
            stopLead: lead,
            stopDuration: 0,
            rendered: rendered > 0 ? RenderedSound(duration: rendered, firstSample: 0, peak: 0.4) : .nothing,
            heardRatio: heardRatio
        )
    }

    @Test
    func silenceRendersNothing() {
        #expect(CancellationLeadMath.rendered(in: mixerOutput(soundAt: nil), renderStart: 10.5, through: 10.9) == .nothing)
    }

    @Test
    func aRenderedBeginningIsMeasured() throws {
        let rendered = CancellationLeadMath.rendered(in: mixerOutput(soundAt: 10.5, sound: 0.0213), renderStart: 10.5, through: 10.9)

        #expect(abs(rendered.duration - 0.0213) <= 1 / sampleRate)
        let first = try #require(rendered.firstSample)
        #expect(abs(first) <= 1 / sampleRate)
        #expect(rendered.peak == 0.4)
    }

    @Test
    func aSoundOutsideTheTrialIsNotCounted() {
        // The previous trial's gun, long before this one's render start.
        #expect(CancellationLeadMath.rendered(in: mixerOutput(soundAt: 10.1), renderStart: 10.5, through: 10.9) == .nothing)
    }

    @Test
    func peakToNoiseNeedsBothStretches() throws {
        var chunks = mixerOutput(soundAt: 10.5, level: 0.4)
        chunks = chunks.map { chunk in
            RecordedChunk(hostSeconds: chunk.hostSeconds, sampleRate: chunk.sampleRate, samples: chunk.samples.map { $0 == 0 ? 0.001 : $0 })
        }

        let ratio = try #require(CancellationLeadMath.peakToNoise(in: chunks, window: 10.45...10.6, noise: 10.1...10.3))
        #expect(abs(ratio - 400) < 1e-3)
        #expect(CancellationLeadMath.peakToNoise(in: chunks, window: 11.5...11.6, noise: 10.1...10.3) == nil)
    }

    @Test
    func aTrialLeaksIfTheMixerRenderedAnyOfIt() {
        #expect(!trial(0.05).leaked)
        #expect(trial(0.05, rendered: 0.001).leaked)

        // The microphone also hears the room; it only confirms.
        let heard = trial(0.05, heardRatio: Double(CalibrationMath.minimumSignalToNoise))
        #expect(heard.heard == true)
        #expect(!heard.leaked)
        #expect(trial(0.05, heardRatio: 2).heard == false)
    }

    @Test
    func theSmallestCleanLeadLiesAboveEveryLeak() {
        let summary = CancellationLeadMath.summarize([
            trial(-0.01, rendered: 0.3, heardRatio: 50),
            trial(0.01, rendered: 0.02),
            trial(0.02),
            // Leaked once at 30 ms, so the clean ones below it don't count.
            trial(0.03, rendered: 0.001),
            trial(0.03),
            trial(0.04, heardRatio: 20),
            trial(0.05),
        ])

        #expect(summary.largestLeakingLead == 0.03)
        #expect(summary.smallestCleanLead == 0.04)
        #expect(summary.largestHeardLead == 0.04)
    }

    @Test
    func withoutAnyLeakEveryLeadIsClean() {
        let summary = CancellationLeadMath.summarize([trial(0.02), trial(0.01)])

        #expect(summary.largestLeakingLead == nil)
        #expect(summary.smallestCleanLead == 0.01)
    }

    @Test
    func theLeadsTriedSpanTheCurrentOne() throws {
        let io = 0.021333
        let leads = CancellationLeadMath.leadsToTry(ioBufferDuration: io)
        let current = OutputTiming.cancellationLead(ioBufferDuration: io)

        let first = try #require(leads.first)
        let last = try #require(leads.last)
        #expect(first < 0)
        #expect(last >= current + 2 * io - 1e-9)
        #expect(leads.contains { abs($0 - current) < io / 8 })
    }
}

/// Opt-in measurement of `OutputTiming.cancellationLead`: schedules the
/// gun, stops it at leads on both sides of the current one and looks at
/// what got out, in the mixer's output and, on the speaker, at the
/// microphone. The table is the result; the current constant only fails
/// the test if something got out at a lead longer than it.
///
/// Inside the serialized `AudioControllerTests`, which share the one
/// system session with it.
extension AudioControllerTests {
    private nonisolated static var leadRequested: Bool {
        ProcessInfo.processInfo.environment["RUN_CANCELLATION_LEAD"] == "1"
    }

    /// The simulator's numbers aren't the device's; one pass shows the test works.
    private static var leadRepetitions: Int {
        #if targetEnvironment(simulator)
        1
        #else
        3
        #endif
    }

    /// Before each render start: long enough to be scheduled, and for the
    /// stop to come after the noise before it was recorded.
    private static let leadScheduleAhead: TimeInterval = 0.5
    /// After each gun's end, for its echo to fade.
    private static let leadPause: TimeInterval = 0.4
    /// The last stretch of a wait is spun out, so the stop is called on time.
    private static let leadSpin: TimeInterval = 0.003
    /// Before each render start, where the microphone's noise is measured.
    private static let leadNoise: ClosedRange<TimeInterval> = -0.45 ... -0.25

    private func leadNow() -> TimeInterval {
        CACurrentMediaTime()
    }

    @Test(.enabled(if: leadRequested), arguments: [AudioOutput.iPhoneSpeaker, .automatic])
    func cancellationLeadIsMeasured(output: AudioOutput) async throws {
        let controller = AudioController(theme: .eng1)
        controller.output = output
        try await controller.activateSession()

        let session = AVAudioSession.sharedInstance()
        let io = session.ioBufferDuration
        let currentLead = OutputTiming.cancellationLead(ioBufferDuration: io)
        let route = controller.currentOutput()?.name ?? "none"

        // The speaker's session records; the automatic one plays only.
        let microphone: MicrophoneRecorder? = output == .iPhoneSpeaker ? MicrophoneRecorder() : nil
        try microphone?.start()

        let mixer = Self.leadMixerTap(of: controller.engine)
        try mixer.install()

        if let microphone {
            await waitUntil(timeout: .seconds(3)) { microphone.isReceivingAudio }
        }
        try await Task.sleep(for: .seconds(0.3))

        var stops: [(renderStart: TimeInterval, lead: TimeInterval, duration: TimeInterval, latency: TimeInterval)] = []
        let gunDuration = controller.duration(of: .go)

        for _ in 0..<Self.leadRepetitions {
            for lead in CancellationLeadMath.leadsToTry(ioBufferDuration: io).shuffled() {
                let gun = try #require(controller.schedule(.go, at: MonotonicTimestamp(seconds: leadNow() + Self.leadScheduleAhead)))
                let render = gun.renderStart.seconds
                let stopAt = render - lead

                try await Task.sleep(for: .seconds(max(0, stopAt - Self.leadSpin - leadNow())))
                while leadNow() < stopAt {}

                let began = leadNow()
                controller.stop()
                let returned = leadNow()

                stops.append((render, render - began, returned - began, gun.audibleOnset.best.seconds - render - gun.basis.onsetOffset))

                try await Task.sleep(for: .seconds(max(0, render + gunDuration + Self.leadPause - leadNow())))
            }
        }

        let mixerOutput = mixer.remove()
        let recording = microphone?.stop() ?? []
        let inputLatency = microphone?.inputLatency ?? 0
        await controller.deactivateSession()

        let trials = stops.map { stop in
            CancellationTrial(
                stopLead: stop.lead,
                stopDuration: stop.duration,
                rendered: CancellationLeadMath.rendered(in: mixerOutput, renderStart: stop.renderStart, through: stop.renderStart + gunDuration),
                heardRatio: microphone == nil ? nil : CancellationLeadMath.peakToNoise(
                    in: recording,
                    window: (stop.renderStart + inputLatency) ... (stop.renderStart + stop.latency + gunDuration + inputLatency),
                    noise: (stop.renderStart + Self.leadNoise.lowerBound + inputLatency) ... (stop.renderStart + Self.leadNoise.upperBound + inputLatency)
                )
            )
        }

        let summary = CancellationLeadMath.summarize(trials)
        Attachment.record(
            Self.leadTable(trials, summary: summary, route: route, io: io, currentLead: currentLead),
            named: "Cancellation lead \(output)"
        )

        // The instrument works: a gun stopped after its render start got out.
        #expect(trials.contains { $0.stopLead < 0 && $0.rendered.duration > 0 })

        // In the simulator the Mac's microphone heard none of the stopped
        // guns in two runs, not even ones rendered at full level; unexplained.
        #if !targetEnvironment(simulator)
        if microphone != nil {
            #expect(trials.contains { $0.stopLead < 0 && $0.heard == true })
        }
        #endif

        if let largest = summary.largestLeakingLead {
            #expect(largest < currentLead, "sound got out \(largest * 1000) ms before the render start; the lead is \(currentLead * 1000) ms")
        }
    }

    private static func leadTable(
        _ trials: [CancellationTrial],
        summary: CancellationLeadMath.Summary,
        route: String,
        io: TimeInterval,
        currentLead: TimeInterval
    ) -> String {
        let reference = trials.map { $0.rendered.peak }.max() ?? 0

        func decibels(_ ratio: Double?) -> String {
            guard let ratio, ratio > 0 else { return "-" }
            return String(format: "%.1f", 20 * log10(ratio))
        }

        var lines = [
            "route: \(route), I/O buffer \(String(format: "%.3f", io * 1000)) ms, current lead \(String(format: "%.3f", currentLead * 1000)) ms",
            "largest lead that let sound through: \(summary.largestLeakingLead.map { String(format: "%.3f ms", $0 * 1000) } ?? "none")",
            "smallest lead that never did: \(summary.smallestCleanLead.map { String(format: "%.3f ms", $0 * 1000) } ?? "none")",
            "largest lead at which the microphone heard something (room noise included): \(summary.largestHeardLead.map { String(format: "%.3f ms", $0 * 1000) } ?? "none")",
            "",
            "lead ms | stop call µs | rendered ms | first sample ms | rendered peak dB (re loudest) | mic peak/noise dB | leaked",
        ]

        for trial in trials.sorted(by: { $0.stopLead > $1.stopLead }) {
            lines.append(
                [
                    String(format: "%.3f", trial.stopLead * 1000),
                    String(format: "%.0f", trial.stopDuration * 1_000_000),
                    String(format: "%.3f", trial.rendered.duration * 1000),
                    trial.rendered.firstSample.map { String(format: "%.3f", $0 * 1000) } ?? "-",
                    reference > 0 && trial.rendered.peak > 0 ? decibels(Double(trial.rendered.peak / reference)) : "-",
                    decibels(trial.heardRatio),
                    trial.leaked ? "yes" : "no",
                ].joined(separator: " | ")
            )
        }
        return lines.joined(separator: "\n")
    }

    /// A tap on the playback engine's mixer: exactly what was rendered,
    /// whatever the output and however loud the room.
    private static func leadMixerTap(of engine: AVAudioEngine) -> MixerTap {
        MixerTap(mixer: engine.mainMixerNode)
    }
}

@MainActor
private final class MixerTap {
    let mixer: AVAudioMixerNode
    let store = RecordedChunkStore()

    init(mixer: AVAudioMixerNode) {
        self.mixer = mixer
    }

    func install() throws {
        try mixer.__installTap(onBus: 0, bufferSize: 1024, format: nil, error: (), block: store.tapBlock())
    }

    func remove() -> [RecordedChunk] {
        mixer.removeTap(onBus: 0)
        return store.recorded
    }
}
