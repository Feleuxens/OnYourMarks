//
//  AudioOutputTests.swift
//  OnYourMarksTests
//

import Testing
import AVFAudio
import Foundation
@testable import OnYourMarks

struct SessionSetupTests {
    @Test
    func automaticStartsKeepPlaybackWithoutMicrophone() {
        let setup = SessionSetup.forStarts(on: .automatic)
        
        #expect(setup.category == .playback)
        #expect(!setup.needsMicrophone)
        #expect(!setup.forcesSpeaker)
    }
    
    @Test(arguments: [SessionSetup.forStarts(on: .iPhoneSpeaker), SessionSetup.forCalibration(on: .iPhoneSpeaker)])
    func speakerForcesSpeakerWithoutBluetooth(setup: SessionSetup) {
        #expect(setup.category == .playAndRecord)
        #expect(setup.forcesSpeaker)
        #expect(setup.options.contains(.defaultToSpeaker))
        #expect(!setup.options.contains(.allowBluetoothA2DP))
        #expect(!setup.options.contains(.allowBluetoothHFP))
    }
    
    @Test
    func automaticCalibrationRecordsWhileKeepingBluetoothOutput() {
        let setup = SessionSetup.forCalibration(on: .automatic)
        
        #expect(setup.needsMicrophone)
        #expect(!setup.forcesSpeaker)
        #expect(setup.options.contains(.allowBluetoothA2DP))
        // HFP would also move the microphone to the headset.
        #expect(!setup.options.contains(.allowBluetoothHFP))
    }
}

struct CalibrationMathTests {
    private let sampleRate = 48_000.0
    
    /// Quiet noise with a click starting at `clickTime`, split into chunks
    /// the way the microphone tap delivers them.
    private func recording(
        start: TimeInterval = 100,
        duration: TimeInterval = 1,
        clickTime: TimeInterval?,
        noise: Float = 0.001,
        clickLevel: Float = 0.5,
        chunkSize: Int = 1024
    ) -> [RecordedChunk] {
        let count = Int(duration * sampleRate)
        var samples = (0..<count).map { index in noise * (index.isMultiple(of: 2) ? 1 : -1) }
        
        if let clickTime {
            let first = Int(((clickTime - start) * sampleRate).rounded(.up))
            // Like the gun: a sharp attack, then near full level for a while.
            for index in first..<min(first + 13_000, count) {
                samples[index] = clickLevel * (index.isMultiple(of: 2) ? 1 : -1)
            }
        }
        
        return stride(from: 0, to: count, by: chunkSize).map { offset in
            RecordedChunk(
                hostSeconds: start + Double(offset) / sampleRate,
                sampleRate: sampleRate,
                samples: Array(samples[offset..<min(offset + chunkSize, count)])
            )
        }
    }
    
    @Test
    func findsClickAcrossChunkBoundaries() throws {
        let click = 100.4321
        let chunks = recording(clickTime: click)
        
        let onset = try #require(CalibrationMath.onset(in: chunks, window: 100.3...100.9, noiseWindow: 100.0...100.2))
        
        #expect(abs(onset - click) < 1 / sampleRate)
    }
    
    @Test
    func noiseSpikeBeforeClickIsIgnored() throws {
        let click = 100.6
        var chunks = recording(clickTime: click)
        
        // A single loud sample 200 ms before the click, e.g. a tap on the table.
        let spikeIndex = Int((0.4 * sampleRate).rounded())
        let chunkSize = chunks[0].samples.count
        var samples = chunks[spikeIndex / chunkSize].samples
        samples[spikeIndex % chunkSize] = 0.3
        let original = chunks[spikeIndex / chunkSize]
        chunks[spikeIndex / chunkSize] = RecordedChunk(hostSeconds: original.hostSeconds, sampleRate: original.sampleRate, samples: samples)
        
        let onset = try #require(CalibrationMath.onset(in: chunks, window: 100.3...100.9, noiseWindow: 100.0...100.2))
        
        #expect(abs(onset - click) < 1 / sampleRate)
    }
    
    @Test
    func clickTooQuietForNoiseIsRejected() {
        let chunks = recording(clickTime: 100.5, noise: 0.05, clickLevel: 0.2)
        
        #expect(CalibrationMath.onset(in: chunks, window: 100.3...100.9, noiseWindow: 100.0...100.2) == nil)
    }
    
    @Test
    func silenceHasNoClick() {
        let chunks = recording(clickTime: nil)
        
        #expect(CalibrationMath.onset(in: chunks, window: 100.3...100.9, noiseWindow: 100.0...100.2) == nil)
    }
    
    @Test
    func summaryUsesMedianAndLargestDeviation() throws {
        let summary = try CalibrationMath.summarize(offsets: [0.180, 0.184, 0.182, 0.186, 0.181, 0.183])
        
        #expect(abs(summary.correction - 0.1825) < 0.000_001)
        #expect(abs(summary.uncertainty - (0.0035 + CalibrationMath.measurementMargin)) < 0.000_001)
    }
    
    @Test
    func tooFewClicksFail() {
        #expect(throws: CalibrationError.self) {
            try CalibrationMath.summarize(offsets: [0.18, 0.18, 0.18])
        }
    }
    
    @Test
    func inconsistentClicksFail() {
        #expect(throws: CalibrationError.self) {
            try CalibrationMath.summarize(offsets: [0.10, 0.15, 0.18, 0.20])
        }
    }
}

struct CalibratedTimingTests {
    @Test
    func correctionShiftsAudibleOnset() {
        let onset = OutputTiming.audibleOnset(
            renderStart: MonotonicTimestamp(seconds: 10),
            latency: 0.1,
            onsetOffset: 0.02,
            correction: 0.08,
            uncertainty: 0.004
        )
        
        #expect(abs(onset.best.seconds - 10.2) < 0.000_000_1)
    }
    
    @Test
    func calibratedUncertaintyNeverBeatsWired() {
        #expect(OutputTiming.uncertainty(calibrated: .fake(uncertainty: 0.0005)) == OutputTiming.wiredUncertainty)
        #expect(OutputTiming.uncertainty(calibrated: .fake(uncertainty: 0.006)) == 0.006)
    }
    
    @Test
    func aLatencyReportedDifferentlyThanAtTheCalibrationWidensIt() {
        var calibration = OutputCalibration.fake(uncertainty: 0.006)
        
        // Nothing to compare with: as measured.
        #expect(OutputTiming.uncertainty(calibrated: calibration, latency: 0.25) == 0.006)
        
        calibration.reportedLatency = 0.18
        #expect(OutputTiming.uncertainty(calibrated: calibration, latency: 0.18) == 0.006)
        #expect(OutputTiming.uncertainty(calibrated: calibration, latency: 0.25) == 0.006 + (0.25 - 0.18))
        #expect(OutputTiming.uncertainty(calibrated: calibration, latency: 0.15) == 0.006 + (0.18 - 0.15))
    }
    
    @Test
    func aCalibrationStoredWithoutItsLatencyStillLoads() throws {
        let stored = Data(
            #"{"routeID":"a","routeName":"A","isBuiltInSpeaker":false,"correction":0.1,"uncertainty":0.002,"clickCount":6,"date":0}"#.utf8
        )
        
        #expect(try JSONDecoder().decode(OutputCalibration.self, from: stored).reportedLatency == nil)
    }
}

@MainActor
struct OutputSettingsTests {
    @Test
    func configWithoutOutputDecodesAsAutomatic() throws {
        let config = try JSONDecoder().decode(StartConfig.self, from: Data(#"{"blockTimeToSet": 5}"#.utf8))
        
        #expect(config.audioOutput == .automatic)
    }
    
    @Test
    func outputSurvivesEncoding() throws {
        var config = StartConfig.standard
        config.audioOutput = .iPhoneSpeaker
        
        let decoded = try JSONDecoder().decode(StartConfig.self, from: JSONEncoder().encode(config))
        
        #expect(decoded.audioOutput == .iPhoneSpeaker)
    }
    
    @Test
    func calibrationStoreRoundTrips() {
        let defaults = UserDefaults(suiteName: "OutputSettingsTests-\(UUID().uuidString)")!
        let store = CalibrationStore(defaults: defaults)
        let calibration = OutputCalibration.fake()
        
        store.save([calibration.routeID: calibration])
        
        #expect(store.load()[calibration.routeID] == calibration)
    }
    
    @Test
    func calibrationStoreIgnoresCorruptData() {
        let defaults = UserDefaults(suiteName: "OutputSettingsTests-\(UUID().uuidString)")!
        defaults.set(Data("nope".utf8), forKey: "outputCalibrations")
        
        #expect(CalibrationStore(defaults: defaults).load().isEmpty)
    }
}
