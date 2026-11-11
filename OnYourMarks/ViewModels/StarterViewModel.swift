//
//  StarterViewModel.swift
//  OnYourMarks
//
//  Created by Felix on 11.06.26.
//

import SwiftUI

@Observable
@MainActor
class StarterViewModel {
    var config: StartConfig {
        didSet {
            configStore.save(config)
            player.theme = config.soundTheme
            motionDetector.compensatesCameraMotion = config.cameraMount == .handheld
            
            if config.audioOutput != oldValue.audioOutput {
                player.output = config.audioOutput
                // The new output applies from the next activation, so let the
                // current one end now instead of after the music resume delay.
                flushPendingSessionDeactivation()
                refreshCurrentOutput()
            }
        }
    }
    
    private let configStore: ConfigStore
    private let calibrationStore: CalibrationStore
    private let player: AudioSessionPlayer
    
    let camera: CameraController
    let motionDetector: PoseMotionDetector
    let engine: StarterEngine
    
    var currentSession: StartSession? {
        engine.currentSession
    }
    var lastSession: StartSession? {
        engine.lastSession
    }
    
    private var cameraEnableTask: Task<Void, Never>?
    /// Other apps' audio resumes once the session is deactivated. After a start
    /// that waits this long, so the runner can get going without distraction.
    private let musicResumeDelay: Duration
    private var sessionDeactivationTask: Task<Void, Never>?
    var cameraEnabled = false
    var cameraPermissionDenied = false
    var errorMessage: String?
    
    /// The system route; with `.iPhoneSpeaker` starts still play on the speaker.
    private(set) var currentOutput: OutputRoute?
    private(set) var calibrations: [String: OutputCalibration]
    private var calibrationTask: Task<Void, Never>?
    
    var isCalibrating: Bool {
        calibrationTask != nil
    }
    
    /// A wireless output the next start would play on without a calibration.
    /// Its latency is only an estimate, so reaction times will be imprecise.
    var uncalibratedWirelessOutput: OutputRoute? {
        guard config.audioOutput == .automatic,
              let output = currentOutput,
              output.isWireless,
              calibrations[output.id] == nil else {
            return nil
        }
        return output
    }
    
    /// The built-in speaker reports its own hardware latency, so only
    /// other outputs gain from a calibration.
    var canCalibrateOutput: Bool {
        switch config.audioOutput {
        case .automatic:
            currentOutput.map { !$0.isBuiltInSpeaker } ?? false
        case .iPhoneSpeaker:
            false
        }
    }
    
    /// The calibration that applies to the next start.
    var activeCalibration: OutputCalibration? {
        switch config.audioOutput {
        case .automatic:
            currentOutput.flatMap { calibrations[$0.id] }
        case .iPhoneSpeaker:
            calibrations.values.first(where: \.isBuiltInSpeaker)
        }
    }

    var isRunning: Bool {
        engine.isRunning
    }
    
    /// The false starts of the current or last start, in the order they
    /// happened, with the athletes if the detector could tell them apart.
    var falseStarts: [AthleteStartResult] {
        engine.athleteResults.filter { $0.decision == .definiteFalseStart }
    }
    
    init(
        configStore: ConfigStore? = nil,
        calibrationStore: CalibrationStore? = nil,
        camera: CameraController? = nil,
        player: AudioSessionPlayer? = nil,
        musicResumeDelay: Duration = .seconds(2)
    ) {
        let configStore = configStore ?? ConfigStore()
        let config = configStore.load()
        self.configStore = configStore
        self.config = config
        
        let calibrationStore = calibrationStore ?? CalibrationStore()
        let calibrations = calibrationStore.load()
        self.calibrationStore = calibrationStore
        self.calibrations = calibrations
        
        let player = player ?? AudioController(theme: config.soundTheme)
        player.output = config.audioOutput
        player.calibrations = calibrations
        self.player = player
        self.musicResumeDelay = musicResumeDelay
        
        let camera = camera ?? CameraController()
        let motionDetector = PoseMotionDetector(camera: camera)
        self.camera = camera
        self.motionDetector = motionDetector
        motionDetector.compensatesCameraMotion = config.cameraMount == .handheld
        self.engine = StarterEngine(player: player, movementDetector: motionDetector)
        
        engine.onRunEnded = { [weak self] in
            self?.runEnded()
        }
        
        engine.onError = { [weak self] message in
            self?.errorMessage = message
        }
        
        player.onUnexpectedStop = { [weak self] reason in
            self?.handleAudioFailure(reason)
        }
        
        player.onRouteChange = { [weak self] in
            self?.refreshCurrentOutput()
        }
        
        refreshCurrentOutput()
    }
    
    func start() {
        guard !isRunning, !isCalibrating else { return }
        
        // Within the resume delay this keeps the session (and the music paused).
        // A deactivation already talking to the system finishes first:
        // the player runs session transitions one after the other.
        sessionDeactivationTask?.cancel()
        sessionDeactivationTask = nil
        
        // The engine activates the session in its preflight, within the
        // wait before the first command.
        engine.start(config: config)
    }
    
    private func runEnded() {
        let delay: Duration = switch engine.lastSession?.outcome {
        case .completed?, .falseStart?:
            musicResumeDelay
        default:
            // on user abort or failure the audio can resume immediately
            .zero
        }
        
        let previous = sessionDeactivationTask
        previous?.cancel()
        
        sessionDeactivationTask = Task { [weak self] in
            await previous?.value
            
            if delay > .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            
            // A new start cancelled us after the sleep had already finished.
            guard !Task.isCancelled else { return }
            
            await self?.player.deactivateSession()
        }
    }
    
    private func flushPendingSessionDeactivation() {
        let previous = sessionDeactivationTask
        previous?.cancel()
        
        sessionDeactivationTask = Task { [weak self] in
            await previous?.value
            await self?.player.deactivateSession()
        }
    }
    
    private func handleAudioFailure(_ reason: String) {
        // If no start is in progress, nothing depends on audio
        guard isRunning else { return }
        
        errorMessage = reason
        abort(reason: reason)
    }
    
    func abort() {
        abort(reason: nil)
    }
    
    private func abort(reason: String?) {
        engine.abort(reason: reason)
    }
    
    func resetConfig() {
        config = .standard
    }
    
    // MARK: - Output
    
    func refreshCurrentOutput() {
        currentOutput = player.currentOutput()
    }
    
    /// Plays and records clicks on the output the next start would use.
    func calibrateOutput() {
        guard !isRunning, !isCalibrating, canCalibrateOutput else { return }
        
        let pendingDeactivation = sessionDeactivationTask
        pendingDeactivation?.cancel()
        sessionDeactivationTask = nil
        
        calibrationTask = Task { [weak self] in
            await pendingDeactivation?.value
            
            guard let self else { return }
            defer {
                calibrationTask = nil
                refreshCurrentOutput()
            }
            
            do {
                let calibration = try await player.calibrateCurrentOutput()
                
                calibrations[calibration.routeID] = calibration
                calibrationStore.save(calibrations)
                player.calibrations = calibrations
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    func removeCalibration(_ calibration: OutputCalibration) {
        calibrations[calibration.routeID] = nil
        calibrationStore.save(calibrations)
        player.calibrations = calibrations
    }

    func enableCamera() {
        guard !isRunning, !cameraEnabled, cameraEnableTask == nil else { return }
        
        cameraEnableTask = Task { [weak self] in
            let granted = await CameraPermission.request()
            
            guard let self else { return }
            
            // stopCamera() cancels this task and cleans up after it,
            // so a cancelled task only has to stop here.
            guard !Task.isCancelled else { return }
            
            defer { cameraEnableTask = nil }
            
            guard granted else {
                cameraPermissionDenied = true
                return
            }
            cameraPermissionDenied = false
            
            guard camera.configureIfNeeded() else {
                errorMessage = String(localized: "The camera could not be configured.")
                return
            }
            camera.start()
            cameraEnabled = true
        }
    }
    
    func disableCamera() {
        guard !isRunning else { return }
        
        stopCamera()
    }
    
    private func stopCamera() {
        cameraEnableTask?.cancel()
        cameraEnableTask = nil
        
        cameraEnabled = false
        motionDetector.reset()
        camera.stop()
    }
    
    /// App was closed or the screen was locked.
    func handleEnteredBackground() {
        if isRunning {
            abort()
        }
        
        // Recording stops in the background; the calibration cleans up after itself.
        calibrationTask?.cancel()
        
        // Not disableCamera(): the camera must go off regardless.
        if cameraEnabled || cameraEnableTask != nil {
            stopCamera()
        }
        flushPendingSessionDeactivation()
    }
}
