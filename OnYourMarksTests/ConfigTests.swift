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

    @Test
    func settingOutOfRangeValuesClamps() {
        var config = StartConfig.standard

        config.blockTimeToReady = -5
        config.blockTimeToSet = 999
        config.blockTimeToStartMin = -1
        config.blockTimeToStartMax = 11
        config.standingTimeToReady = 21
        config.standingTimeToStartMin = -3
        config.standingTimeToStartMax = 100

        #expect(config.blockTimeToReady == StartConfig.readyRange.lowerBound)
        #expect(config.blockTimeToSet == StartConfig.setRange.upperBound)
        #expect(config.blockTimeToStartMin == StartConfig.startRange.lowerBound)
        #expect(config.blockTimeToStartMax == StartConfig.startRange.upperBound)
        #expect(config.standingTimeToReady == StartConfig.readyRange.upperBound)
        #expect(config.standingTimeToStartMin == StartConfig.startRange.lowerBound)
        #expect(config.standingTimeToStartMax == StartConfig.startRange.upperBound)
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
