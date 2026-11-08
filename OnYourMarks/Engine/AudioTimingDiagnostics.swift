//
//  AudioTimingSnapshot.swift
//  OnYourMarks
//
//  Created by Felix on 28.08.26.
//

import AVFAudio
import Foundation
import QuartzCore
import OSLog

nonisolated struct AudioTimingSnapshot: Sendable {
    let timestamp: MonotonicTimestamp
    
    let routeDescription: String
    
    let sampleRate: Double
    let ioBufferDuration: TimeInterval
    let outputLatency: TimeInterval
    
    let outputNodePresentationLatency: TimeInterval?
    let outputNodeOutputPresentationLatency: TimeInterval?
    let mainMixerOutputPresentationLatency: TimeInterval?
    
    /// Sample rate of the main mixer's output (what the engine renders at).
    let mixerOutputSampleRate: Double?
    /// Hardware-side sample rate of the output node.
    let hardwareOutputSampleRate: Double?
    
    let clockRoundTripError: TimeInterval
    
    /// `CACurrentMediaTime()` minus `mach_absolute_time()` converted by
    /// `AVAudioTime`, read back to back. Verifies that both clocks share
    /// the same base; expected to be below 1 µs.
    let currentClockDifference: TimeInterval
}

@MainActor
final class AudioTimingDiagnostics {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks",
        category: "AudioTiming"
    )
    
    private let clockBridge = AudioHostClockBridge()
    
    func capture(
        engine: AVAudioEngine? = nil
    ) -> AudioTimingSnapshot {
        let session = AVAudioSession.sharedInstance()
        
        let nowSeconds = CACurrentMediaTime()
        
        let now = MonotonicTimestamp(seconds: nowSeconds)
        
        // Test:
        //
        // CACurrentMediaTime
        //   → AVAudio host ticks
        //   → seconds
        //
        // Ideally this should introduce essentially no error.
        let convertedHostTime =
            clockBridge.hostTime(for: now)

        let roundTripped =
            clockBridge.timestamp(
                forHostTime: convertedHostTime
            )

        let roundTripError =
            roundTripped.seconds - now.seconds

        // Read the raw host clock and the media clock back to back.
        // The round trip above only proves the conversion is invertible;
        // this proves CACurrentMediaTime() and AVAudioTime host time
        // refer to the same clock. The difference contains the (tiny)
        // gap between the two reads.
        let hostTicks = mach_absolute_time()
        let mediaSeconds = CACurrentMediaTime()

        let currentClockDifference =
            mediaSeconds -
            AVAudioTime.seconds(forHostTime: hostTicks)

        let routeDescription =
            describeRoute(session.currentRoute)

        let outputNodePresentationLatency: TimeInterval?
        let outputNodeOutputPresentationLatency: TimeInterval?
        let mainMixerOutputPresentationLatency: TimeInterval?
        
        let mixerOutputSampleRate: Double?
        let hardwareOutputSampleRate: Double?
        
        if let engine {
            outputNodePresentationLatency =
                engine.outputNode.presentationLatency

            outputNodeOutputPresentationLatency =
                engine.outputNode.outputPresentationLatency

            mainMixerOutputPresentationLatency =
                engine.mainMixerNode.outputPresentationLatency
            
            mixerOutputSampleRate =
                engine.mainMixerNode.outputFormat(forBus: 0).sampleRate

            hardwareOutputSampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        } else {
            outputNodePresentationLatency = nil
            outputNodeOutputPresentationLatency = nil
            mainMixerOutputPresentationLatency = nil
            mixerOutputSampleRate = nil
            hardwareOutputSampleRate = nil
        }

        return AudioTimingSnapshot(
            timestamp: now,
            routeDescription: routeDescription,

            sampleRate: session.sampleRate,
            ioBufferDuration: session.ioBufferDuration,
            outputLatency: session.outputLatency,

            outputNodePresentationLatency:
                outputNodePresentationLatency,

            outputNodeOutputPresentationLatency:
                outputNodeOutputPresentationLatency,

            mainMixerOutputPresentationLatency:
                mainMixerOutputPresentationLatency,
            
            mixerOutputSampleRate:
                mixerOutputSampleRate,

            hardwareOutputSampleRate:
                hardwareOutputSampleRate,
            
            clockRoundTripError: roundTripError,

            currentClockDifference:
                currentClockDifference
        )
    }
    
    private func describeRoute(
        _ route: AVAudioSessionRouteDescription
    ) -> String {
        guard !route.outputs.isEmpty else {
            return "No output route"
        }
        
        return route.outputs.map { output in
            "\(output.portName) [\(output.portType.rawValue)]"
        }.joined(separator: ", ")
    }
    
    func log(
        engine: AVAudioEngine? = nil,
        label: String
    ) {
        let snapshot = capture(
            engine: engine
        )

        logger.info(
            """
            ===== Audio Timing: \(label, privacy: .public) =====
            Route: \(snapshot.routeDescription, privacy: .public)

            Sample rate:
              \(snapshot.sampleRate, format: .fixed(precision: 2)) Hz

            I/O buffer:
              \(snapshot.ioBufferDuration * 1000, format: .fixed(precision: 3)) ms

            AVAudioSession.outputLatency:
              \(snapshot.outputLatency * 1000, format: .fixed(precision: 3)) ms

            Output node presentationLatency:
              \(self.optionalMilliseconds(snapshot.outputNodePresentationLatency), privacy: .public)

            Output node outputPresentationLatency:
              \(self.optionalMilliseconds(snapshot.outputNodeOutputPresentationLatency), privacy: .public)

            Mixer outputPresentationLatency:
              \(self.optionalMilliseconds(snapshot.mainMixerOutputPresentationLatency), privacy: .public)

            Mixer output / hardware sample rate:
              \(self.optionalHertz(snapshot.mixerOutputSampleRate), privacy: .public) / \(self.optionalHertz(snapshot.hardwareOutputSampleRate), privacy: .public)
            
            Host-clock round-trip error:
              \(snapshot.clockRoundTripError * 1_000_000, format: .fixed(precision: 3)) µs

            Media clock - host clock difference:
              \(snapshot.currentClockDifference * 1_000_000, format: .fixed(precision: 3)) µs
            ==========================================
            """
        )
    }

    private func optionalMilliseconds(
        _ value: TimeInterval?
    ) -> String {
        guard let value else {
            return "N/A - AVAudioEngine not active yet"
        }

        return String(
            format: "%.3f ms",
            value * 1000
        )
    }
    
    private func optionalHertz(
        _ value: Double?
    ) -> String {
        guard let value else {
            return "N/A - AVAudioEngine is not active yet"
        }
        
        return String(format: "%.0f Hz", value)
    }
}
