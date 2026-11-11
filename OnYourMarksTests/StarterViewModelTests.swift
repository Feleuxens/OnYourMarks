//
//  StarterViewModelTests.swift
//  OnYourMarksTests
//

import Testing
import Foundation
import QuartzCore
@testable import OnYourMarks

@MainActor
struct StarterViewModelTests {
    /// A view model with instant phases, a fake audio session and its own defaults.
    private func makeViewModel(
        player: FakeSessionPlayer,
        musicResumeDelay: Duration = .seconds(60),
        timeToStart: Double = 0,
        calibrationStore: CalibrationStore? = nil
    ) -> StarterViewModel {
        let defaults = UserDefaults(suiteName: "StarterViewModelTests-\(UUID().uuidString)")!
        let store = ConfigStore(defaults: defaults)

        var config = StartConfig.standard
        config.blockTimeToReady = 0
        config.blockTimeToSet = 0
        config.blockTimeToStartMin = timeToStart
        config.blockTimeToStartMax = timeToStart
        store.save(config)

        return StarterViewModel(
            configStore: store,
            calibrationStore: calibrationStore ?? CalibrationStore(defaults: defaults),
            player: player,
            musicResumeDelay: musicResumeDelay
        )
    }

    /// Gives already scheduled tasks a chance to run before checking that nothing happened.
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    // MARK: - Activation window

    @Test
    func startWaitsForActivationBeforeRunningSequence() async {
        let player = FakeSessionPlayer()
        player.holdsActivation = true
        let vm = makeViewModel(player: player)

        vm.start()
        await waitUntil { player.isActivationPending }

        #expect(vm.isRunning)
        #expect(vm.engine.state == .preparing)
        #expect(player.played.isEmpty)

        player.releaseActivation()
        await waitUntil { vm.lastSession != nil && !vm.isRunning }

        #expect(player.played == [.onYourMarks, .set, .go])
        #expect(vm.lastSession?.outcome == .completed)
    }

    @Test
    func secondStartDuringActivationIsIgnored() async {
        let player = FakeSessionPlayer()
        player.holdsActivation = true
        let vm = makeViewModel(player: player)

        vm.start()
        await waitUntil { player.isActivationPending }

        vm.start()
        await settle()

        #expect(player.activateCount == 1)

        player.releaseActivation()
        await waitUntil { vm.lastSession != nil && !vm.isRunning }

        #expect(player.played == [.onYourMarks, .set, .go])
    }

    @Test
    func abortDuringActivationGivesSessionBackAndNeverStarts() async {
        let player = FakeSessionPlayer()
        player.holdsActivation = true
        let vm = makeViewModel(player: player)

        vm.start()
        await waitUntil { player.isActivationPending }

        vm.abort()

        // The run ends right away; the activation still finishes and is undone.
        #expect(!vm.isRunning)

        player.releaseActivation()
        await waitUntil { player.deactivateCount == 1 }

        #expect(!player.isSessionActive)
        #expect(player.played.isEmpty)
        #expect(vm.lastSession?.outcome == .aborted)
        #expect(vm.errorMessage == nil)
    }

    @Test
    func startAfterAbortedActivationWorks() async {
        let player = FakeSessionPlayer()
        player.holdsActivation = true
        let vm = makeViewModel(player: player)

        vm.start()
        await waitUntil { player.isActivationPending }
        vm.abort()
        player.releaseActivation()
        await waitUntil { !vm.isRunning }

        player.holdsActivation = false
        vm.start()
        await waitUntil { vm.lastSession != nil && !vm.isRunning }

        #expect(player.activateCount == 2)
        #expect(player.played == [.onYourMarks, .set, .go])
    }

    @Test
    func audioFailureDuringActivationCancelsStart() async {
        let player = FakeSessionPlayer()
        player.holdsActivation = true
        let vm = makeViewModel(player: player)

        vm.start()
        await waitUntil { player.isActivationPending }

        player.failUnexpectedly("Output changed")
        player.releaseActivation()
        await waitUntil { player.deactivateCount == 1 }

        #expect(!vm.isRunning)
        #expect(vm.errorMessage == "Output changed")
        #expect(player.played.isEmpty)
    }

    @Test
    func backgroundDuringActivationAbortsAndDeactivates() async {
        let player = FakeSessionPlayer()
        player.holdsActivation = true
        let vm = makeViewModel(player: player)

        vm.start()
        await waitUntil { player.isActivationPending }

        vm.handleEnteredBackground()
        player.releaseActivation()
        await waitUntil { !vm.isRunning && !player.isSessionActive }

        #expect(player.played.isEmpty)
        #expect(!vm.cameraEnabled)
    }

    // MARK: - Activation failure

    @Test
    func activationFailureShowsErrorAndDoesNotStart() async {
        let player = FakeSessionPlayer()
        player.activationError = FakeActivationError()
        let vm = makeViewModel(player: player)

        vm.start()
        await waitUntil { !vm.isRunning }

        #expect(vm.errorMessage?.contains("Activation refused") == true)
        #expect(player.played.isEmpty)
        #expect(vm.lastSession?.outcome == vm.errorMessage.map(StartSessionOutcome.failed))
    }

    @Test
    func activationFailureAfterAbortShowsNoError() async {
        let player = FakeSessionPlayer()
        player.holdsActivation = true
        player.activationError = FakeActivationError()
        let vm = makeViewModel(player: player)

        vm.start()
        await waitUntil { player.isActivationPending }

        vm.abort()
        player.releaseActivation()
        await waitUntil { !vm.isRunning }

        #expect(vm.errorMessage == nil)
    }

    // MARK: - Session deactivation after a run

    @Test
    func completedRunDeactivatesAfterResumeDelay() async {
        let player = FakeSessionPlayer()
        let vm = makeViewModel(player: player, musicResumeDelay: .milliseconds(200))

        vm.start()
        await waitUntil { vm.lastSession?.outcome == .completed }
        await settle()

        // Music stays paused for a moment after the gun.
        #expect(player.isSessionActive)

        await waitUntil { !player.isSessionActive }
        #expect(player.deactivateCount == 1)
    }

    @Test
    func abortedRunDeactivatesImmediately() async {
        let player = FakeSessionPlayer()
        let vm = makeViewModel(player: player, timeToStart: 10)

        vm.start()
        await waitUntil { vm.engine.state == .waitForStart }

        vm.abort()
        await waitUntil { !player.isSessionActive }

        #expect(vm.lastSession?.outcome == .aborted)
        #expect(player.deactivateCount == 1)
    }

    @Test
    func startWithinResumeDelayKeepsSession() async {
        let player = FakeSessionPlayer()
        let vm = makeViewModel(player: player)

        vm.start()
        await waitUntil { vm.lastSession != nil && !vm.isRunning }

        vm.start()
        await waitUntil { player.played.count == 6 && !vm.isRunning }
        await settle()

        #expect(player.deactivateCount == 0)
        #expect(player.isSessionActive)
    }

    @Test
    func backgroundFlushesPendingDeactivation() async {
        let player = FakeSessionPlayer()
        let vm = makeViewModel(player: player)

        vm.start()
        await waitUntil { vm.lastSession != nil && !vm.isRunning }
        #expect(player.isSessionActive)

        vm.handleEnteredBackground()
        await waitUntil { !player.isSessionActive }

        #expect(player.deactivateCount == 1)
    }

    // MARK: - Audio failures

    @Test
    func audioFailureWhileRunningAbortsWithReason() async {
        let player = FakeSessionPlayer()
        let vm = makeViewModel(player: player, timeToStart: 10)

        vm.start()
        await waitUntil { vm.engine.state == .waitForStart }

        player.failUnexpectedly("Output changed")

        #expect(!vm.isRunning)
        #expect(vm.errorMessage == "Output changed")
        #expect(vm.lastSession?.outcome == .failed("Output changed"))

        await waitUntil { !player.isSessionActive }
    }

    @Test
    func audioFailureWhenIdleIsIgnored() {
        let player = FakeSessionPlayer()
        let vm = makeViewModel(player: player)

        player.failUnexpectedly("Output changed")

        #expect(vm.errorMessage == nil)
        #expect(vm.lastSession == nil)
    }

    // MARK: - Config

    @Test
    func configChangesAreSavedAndForwardedToPlayer() {
        let defaults = UserDefaults(suiteName: "StarterViewModelTests-\(UUID().uuidString)")!
        let store = ConfigStore(defaults: defaults)
        let player = FakeSessionPlayer()
        let vm = StarterViewModel(configStore: store, player: player)

        vm.config.blockTimeToSet = 7

        #expect(store.load().blockTimeToSet == 7)
        #expect(player.theme == vm.config.soundTheme)

        vm.resetConfig()

        #expect(store.load().blockTimeToSet == StartConfig.standard.blockTimeToSet)
    }
    
    // MARK: - Output and calibration
    
    @Test
    func changingOutputForwardsItAndEndsLingeringSession() async {
        let player = FakeSessionPlayer()
        let vm = makeViewModel(player: player)
        
        vm.start()
        await waitUntil { vm.lastSession != nil && !vm.isRunning }
        #expect(player.isSessionActive, "kept for the music resume delay")
        
        vm.config.audioOutput = .iPhoneSpeaker
        
        #expect(player.output == .iPhoneSpeaker)
        await waitUntil { !player.isSessionActive }
    }
    
    @Test
    func savedOutputAndCalibrationsReachPlayerOnLaunch() {
        let defaults = UserDefaults(suiteName: "StarterViewModelTests-\(UUID().uuidString)")!
        var config = StartConfig.standard
        config.audioOutput = .iPhoneSpeaker
        ConfigStore(defaults: defaults).save(config)
        let calibration = OutputCalibration.fake()
        CalibrationStore(defaults: defaults).save([calibration.routeID: calibration])
        
        let player = FakeSessionPlayer()
        _ = StarterViewModel(
            configStore: ConfigStore(defaults: defaults),
            calibrationStore: CalibrationStore(defaults: defaults),
            player: player
        )
        
        #expect(player.output == .iPhoneSpeaker)
        #expect(player.calibrations[calibration.routeID] == calibration)
    }
    
    @Test
    func successfulCalibrationIsStoredAndApplied() async {
        let player = FakeSessionPlayer()
        let calibration = OutputCalibration.fake(routeID: "headphones")
        player.calibrationResult = calibration
        let defaults = UserDefaults(suiteName: "StarterViewModelTests-\(UUID().uuidString)")!
        let store = CalibrationStore(defaults: defaults)
        let vm = makeViewModel(player: player, calibrationStore: store)
        
        vm.calibrateOutput()
        #expect(vm.isCalibrating)
        await waitUntil { !vm.isCalibrating }
        
        #expect(vm.activeCalibration == calibration)
        #expect(player.calibrations["headphones"] == calibration)
        #expect(store.load()["headphones"] == calibration)
        #expect(vm.errorMessage == nil)
    }
    
    @Test
    func failedCalibrationShowsErrorAndKeepsOldOne() async {
        let player = FakeSessionPlayer()
        let old = OutputCalibration.fake(routeID: "headphones", correction: 0.1)
        let defaults = UserDefaults(suiteName: "StarterViewModelTests-\(UUID().uuidString)")!
        let store = CalibrationStore(defaults: defaults)
        store.save([old.routeID: old])
        player.calibrationError = CalibrationError.tooFewClicksHeard(heard: 2, needed: 4)
        let vm = makeViewModel(player: player, calibrationStore: store)
        
        vm.calibrateOutput()
        await waitUntil { !vm.isCalibrating }
        
        #expect(vm.errorMessage != nil)
        #expect(vm.activeCalibration == old)
    }
    
    @Test
    func noStartWhileCalibrating() async {
        let player = FakeSessionPlayer()
        player.calibrationResult = .fake()
        let vm = makeViewModel(player: player)
        
        vm.calibrateOutput()
        vm.start()
        
        #expect(!vm.isRunning)
        #expect(player.activateCount == 0)
        await waitUntil { !vm.isCalibrating }
    }
    
    @Test
    func noCalibrationWhileRunning() async {
        let player = FakeSessionPlayer()
        let vm = makeViewModel(player: player, timeToStart: 10)
        
        vm.start()
        await waitUntil { vm.engine.state == .waitForStart }
        
        vm.calibrateOutput()
        
        #expect(!vm.isCalibrating)
        #expect(player.calibrationCount == 0)
        vm.abort()
    }
    
    @Test
    func speakerModeUsesSpeakerCalibration() {
        let player = FakeSessionPlayer()
        let speaker = OutputCalibration.fake(routeID: "speaker", isBuiltInSpeaker: true)
        let headphones = OutputCalibration.fake(routeID: "headphones")
        let defaults = UserDefaults(suiteName: "StarterViewModelTests-\(UUID().uuidString)")!
        let store = CalibrationStore(defaults: defaults)
        store.save([speaker.routeID: speaker, headphones.routeID: headphones])
        let vm = makeViewModel(player: player, calibrationStore: store)
        
        // The system route stays on the headphones while the session is inactive.
        #expect(vm.activeCalibration == headphones)
        
        vm.config.audioOutput = .iPhoneSpeaker
        
        #expect(vm.activeCalibration == speaker)
    }
    
    @Test
    func routeChangeUpdatesCurrentOutput() {
        let player = FakeSessionPlayer()
        let vm = makeViewModel(player: player)
        let speaker = OutputRoute(id: "speaker", name: "Speaker", isWireless: false, isBuiltInSpeaker: true)
        
        player.changeRoute(to: speaker)
        
        #expect(vm.currentOutput == speaker)
    }
    
    @Test
    func removingCalibrationForgetsIt() async {
        let player = FakeSessionPlayer()
        let calibration = OutputCalibration.fake()
        let defaults = UserDefaults(suiteName: "StarterViewModelTests-\(UUID().uuidString)")!
        let store = CalibrationStore(defaults: defaults)
        store.save([calibration.routeID: calibration])
        let vm = makeViewModel(player: player, calibrationStore: store)
        
        vm.removeCalibration(calibration)
        
        #expect(vm.activeCalibration == nil)
        #expect(player.calibrations.isEmpty)
        #expect(store.load().isEmpty)
    }
    
    // MARK: - Uncalibrated wireless warning
    
    @Test
    func warnsForUncalibratedWirelessOutput() {
        let player = FakeSessionPlayer()
        let vm = makeViewModel(player: player)
        
        #expect(vm.uncalibratedWirelessOutput?.id == "headphones")
    }
    
    @Test
    func noWarningOnceCalibrated() async {
        let player = FakeSessionPlayer()
        player.calibrationResult = .fake(routeID: "headphones")
        let vm = makeViewModel(player: player)
        
        vm.calibrateOutput()
        await waitUntil { !vm.isCalibrating }
        
        #expect(vm.uncalibratedWirelessOutput == nil)
    }
    
    @Test
    func noWarningWhenForcingSpeaker() {
        let player = FakeSessionPlayer()
        let vm = makeViewModel(player: player)
        
        vm.config.audioOutput = .iPhoneSpeaker
        
        #expect(vm.uncalibratedWirelessOutput == nil)
    }
    
    @Test
    func noWarningForWiredOutput() {
        let player = FakeSessionPlayer()
        let vm = makeViewModel(player: player)
        
        player.changeRoute(to: OutputRoute(id: "speaker", name: "Speaker", isWireless: false, isBuiltInSpeaker: true))
        
        #expect(vm.uncalibratedWirelessOutput == nil)
    }
    
    @Test
    func warningAppearsWhenHeadphonesConnect() {
        let player = FakeSessionPlayer()
        player.route = OutputRoute(id: "speaker", name: "Speaker", isWireless: false, isBuiltInSpeaker: true)
        let vm = makeViewModel(player: player)
        #expect(vm.uncalibratedWirelessOutput == nil)
        
        player.changeRoute(to: OutputRoute(id: "airpods", name: "AirPods", isWireless: true, isBuiltInSpeaker: false))
        
        #expect(vm.uncalibratedWirelessOutput?.name == "AirPods")
    }
    
    // MARK: - Calibration availability
    
    @Test
    func wirelessOutputCanBeCalibrated() {
        let vm = makeViewModel(player: FakeSessionPlayer())
        
        #expect(vm.canCalibrateOutput)
    }
    
    @Test
    func builtInSpeakerNeedsNoCalibration() async {
        let player = FakeSessionPlayer()
        player.route = OutputRoute(id: "speaker", name: "Speaker", isWireless: false, isBuiltInSpeaker: true)
        player.calibrationResult = .fake(routeID: "speaker", isBuiltInSpeaker: true)
        let vm = makeViewModel(player: player)
        
        #expect(!vm.canCalibrateOutput)
        
        vm.calibrateOutput()
        await settle()
        
        #expect(player.calibrationCount == 0)
    }
    
    @Test
    func forcedSpeakerNeedsNoCalibration() {
        let vm = makeViewModel(player: FakeSessionPlayer())
        
        vm.config.audioOutput = .iPhoneSpeaker
        
        #expect(!vm.canCalibrateOutput)
    }

    @Test
    @MainActor
    func falseStartIsExposedUntilTheNextStart() async {
        let vm = makeViewModel(player: FakeSessionPlayer(), timeToStart: 10)
        #expect(vm.falseStarts.isEmpty)

        vm.start()
        await waitUntil { vm.engine.state == .waitForStart }

        vm.motionDetector.onEvent?(.movement(MovementObservation(time: MonotonicTimestamp(seconds: CACurrentMediaTime()))))
        await waitUntil { !vm.isRunning }

        #expect(vm.falseStarts.map { $0.decision } == [.definiteFalseStart])
        #expect(vm.falseStarts.first?.position == nil)

        vm.start()
        #expect(vm.falseStarts.isEmpty)
        vm.abort()
    }
}
