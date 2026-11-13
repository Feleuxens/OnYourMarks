//
//  ConfigTests.swift
//  OnYourMarksTests
//

import Testing
import Foundation
@testable import OnYourMarks

@MainActor
struct ConfigTests {
    private func makeStore() -> (ConfigStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "ConfigTests-\(UUID().uuidString)")!
        return (ConfigStore(defaults: defaults), defaults)
    }

    @Test(arguments: [
        (\StartConfig.blockTimeToReady, StartConfig.readyRange),
        (\StartConfig.standingTimeToReady, StartConfig.readyRange),
        (\StartConfig.blockTimeToSet, StartConfig.setRange),
        (\StartConfig.blockTimeToStartMin, StartConfig.startRange),
        (\StartConfig.blockTimeToStartMax, StartConfig.startRange),
        (\StartConfig.standingTimeToStartMin, StartConfig.startRange),
        (\StartConfig.standingTimeToStartMax, StartConfig.startRange),
    ])
    func settingOutOfRangeValuesClamps(
        property: WritableKeyPath<StartConfig, Double> & Sendable,
        range: ClosedRange<Double>
    ) {
        var config = StartConfig.standard
        
        config[keyPath: property] = range.lowerBound - 1
        #expect(config[keyPath: property] == range.lowerBound)
        
        config[keyPath: property] = range.upperBound + 1
        #expect(config[keyPath: property] == range.upperBound)
    }
    
    @Test
    func decodingClampsOutOfRangeValues() throws {
        let json = #"{"blockTimeToReady": 50, "blockTimeToSet": -2, "blockTimeToStartMax": 42}"#

        let config = try JSONDecoder().decode(StartConfig.self, from: Data(json.utf8))

        #expect(config.blockTimeToReady == StartConfig.readyRange.upperBound)
        #expect(config.blockTimeToSet == StartConfig.setRange.lowerBound)
        #expect(config.blockTimeToStartMax == StartConfig.startRange.upperBound)
    }

    @Test
    func decodingMissingKeysUsesDefaults() throws {
        let json = #"{"blockTimeToSet": 5}"#

        let config = try JSONDecoder().decode(StartConfig.self, from: Data(json.utf8))
        let defaults = StartConfig.standard

        #expect(config.blockTimeToSet == 5)
        #expect(config.blockTimeToReady == defaults.blockTimeToReady)
        #expect(config.standingTimeToStartMax == defaults.standingTimeToStartMax)
        #expect(config.startType == defaults.startType)
        #expect(config.soundTheme == defaults.soundTheme)
    }

    @Test
    func cameraMountDefaultsToTripodAndRoundTrips() throws {
        let old = try JSONDecoder().decode(StartConfig.self, from: Data(#"{"blockTimeToSet": 5}"#.utf8))
        #expect(old.cameraMount == .tripod)

        var config = StartConfig.standard
        config.cameraMount = .handheld

        let restored = try JSONDecoder().decode(StartConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.cameraMount == .handheld)
    }

    @Test
    func frameRateDefaultsTo120AndSurvivesUnknownValues() throws {
        let old = try JSONDecoder().decode(StartConfig.self, from: Data(#"{"blockTimeToSet": 5}"#.utf8))
        #expect(old.frameRate == .fps120)

        let unknown = try JSONDecoder().decode(StartConfig.self, from: Data(#"{"frameRate": 90}"#.utf8))
        #expect(unknown.frameRate == .fps120)

        var config = StartConfig.standard
        config.frameRate = .fps240

        let restored = try JSONDecoder().decode(StartConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.frameRate == .fps240)
    }

    @Test
    func theRecordingAfterTheStartStaysInItsRangeAndHasADefault() throws {
        var config = StartConfig.standard
        config.recordingAfterStart = 60
        #expect(config.recordingAfterStart == StartConfig.recordingAfterStartRange.upperBound)

        config.recordingAfterStart = 4
        let restored = try JSONDecoder().decode(StartConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.recordingAfterStart == 4)

        // Stored before the setting existed.
        let old = try JSONDecoder().decode(StartConfig.self, from: Data("{}".utf8))
        #expect(old.recordingAfterStart == StartConfig.standard.recordingAfterStart)
    }

    @Test
    func falseStartsAreRecalledUnlessSwitchedOff() throws {
        var config = StartConfig.standard
        #expect(config.recallsFalseStarts)

        config.recallsFalseStarts = false
        let restored = try JSONDecoder().decode(StartConfig.self, from: JSONEncoder().encode(config))
        #expect(!restored.recallsFalseStarts)

        let old = try JSONDecoder().decode(StartConfig.self, from: Data("{}".utf8))
        #expect(old.recallsFalseStarts)
    }

    @Test
    func storeRoundTripsConfig() {
        let (store, _) = makeStore()

        var config = StartConfig.standard
        config.blockTimeToSet = 3.5
        config.standingTimeToStartMin = 0.5
        store.save(config)

        let loaded = store.load()

        #expect(loaded.blockTimeToSet == 3.5)
        #expect(loaded.standingTimeToStartMin == 0.5)
    }

    @Test
    func storeFallsBackToStandardWhenEmpty() {
        let (store, _) = makeStore()

        #expect(store.load().blockTimeToSet == StartConfig.standard.blockTimeToSet)
    }

    @Test
    func storeFallsBackToStandardOnCorruptData() {
        let (store, defaults) = makeStore()
        defaults.set(Data("not json".utf8), forKey: "starterConfig")

        #expect(store.load().blockTimeToSet == StartConfig.standard.blockTimeToSet)
    }
}
