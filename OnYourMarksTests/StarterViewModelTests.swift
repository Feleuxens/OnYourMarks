//
//  StarterViewModelTests.swift
//  OnYourMarksTests
//

import Testing
import Foundation
@testable import OnYourMarks

@MainActor
struct StarterViewModelTests {
    /// A view model with instant phases, a fake audio session and its own defaults.
    private func makeViewModel(
        player: FakeSessionPlayer,
        musicResumeDelay: Duration = .seconds(60),
        timeToStart: Double = 0
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
        #expect(vm.isStarting)
        #expect(vm.engine.state == .idle)
        #expect(player.played.isEmpty)

        player.releaseActivation()
        await waitUntil { vm.lastSession != nil && !vm.isRunning }

        #expect(player.played == [.onYourMarks, .set, .go])
        #expect(vm.lastSession?.outcome == .completed)
        #expect(!vm.isStarting)
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

        // The start task still owns the activation until it has cleaned up.
        #expect(vm.isRunning)

        player.releaseActivation()
        await waitUntil { !vm.isRunning }

        #expect(player.deactivateCount == 1)
        #expect(!player.isSessionActive)
        #expect(player.played.isEmpty)
        #expect(vm.lastSession == nil)
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
        await waitUntil { !vm.isRunning }

        #expect(vm.errorMessage == "Output changed")
        #expect(player.played.isEmpty)
        #expect(player.deactivateCount == 1)
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
        #expect(vm.lastSession == nil)
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
}
