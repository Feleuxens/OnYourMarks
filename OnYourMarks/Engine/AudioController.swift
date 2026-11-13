//
//  AudioController.swift
//  OnYourMarks
//
//  Created by Felix on 12.06.26.
//

import AVFoundation
import OSLog

@MainActor
final class AudioController: AudioSessionPlayer {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks",
        category: "Audio"
    )
    
    var theme: SoundTheme {
        didSet {
            guard theme != oldValue else { return }
            loadSounds(theme)
        }
    }
    
    /// Audio output can't be trusted anymore; argument shown to the user
    var onUnexpectedStop: ((String) -> Void)?
    
    /// The system route changed, whether or not the session is active.
    var onRouteChange: (() -> Void)?
    
    /// Applies from the next activation.
    var output: AudioOutput = .automatic
    
    /// By route ID; applied to every signal scheduled on that route.
    var calibrations: [String: OutputCalibration] = [:]

    /// Readable for tests, which stop it to simulate a hardware reconfiguration.
    private(set) var engine = AVAudioEngine()
    
    /// Host time until which the last played or scheduled sound lasts.
    /// A reconfiguration before then has cut it off.
    private var soundEndsAt: TimeInterval?
    private var nodes: [Signal: AVAudioPlayerNode] = [:]
    private var buffers: [Signal: AVAudioPCMBuffer] = [:]
    
    /// Offsets for the audible transient
    private(set) var onsetOffsets: [Signal: TimeInterval] = [:]
    
    private(set) var isSessionActive = false
    
    /// What the active session was configured for.
    private var activeSetup: SessionSetup?
    
    /// Output ports at activations. Different set means route changed
    private var activeOutputPortIDs: [String] = []
    /// The most recently requested activation or deactivation.
    private var sessionTransition: Task<Void, Never>?
    
    private let timingDiagnostics = AudioTimingDiagnostics()
    private let clockBridge = AudioHostClockBridge()
    private let clock = SystemMonotonicClock()
    
    private var observerTokens: [NotificationCenter.ObservationToken] = []
        
    init(theme: SoundTheme = .eng1) {
        self.theme = theme
        attachNodes()
        loadSounds(theme)
        observeSystemNotifications()
    }
    
    isolated deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
    
    /// Talks to the audio server, which can block while a session is active,
    /// so it stays off the main actor.
    ///
    /// Throws instead of carrying on: with the wrong category the signals
    /// would play on an output the user didn't choose.
    @concurrent
    private nonisolated static func configureCategory(
        of session: AVAudioSession,
        for setup: SessionSetup
    ) async throws {
        try session.setCategory(setup.category, mode: .default, options: setup.options)
    }
    
    /// The async `activate()` brings up no microphone input (iOS 27.2: the
    /// input node reports 0 channels); `setActive` does. It blocks, so it
    /// stays off the main actor.
    @concurrent
    private nonisolated static func activateWithInput(_ session: AVAudioSession) async throws {
        try session.setActive(true)
    }
    
    @concurrent
    private nonisolated static func overrideToSpeaker(_ session: AVAudioSession, logger: Logger) async {
        do {
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            logger.error("Could not force the speaker: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private static func ensureMicrophoneAccess() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else {
                throw AudioSessionError.microphoneDenied
            }
        default:
            throw AudioSessionError.microphoneDenied
        }
    }
    
    func logTimingDiagnostics(label: String) {
        timingDiagnostics.log(engine: engine.isRunning ? engine : nil, label: label)
    }
    
    /// Activates the session for starts on the chosen output and starts the engine.
    ///
    /// Transitions are serialized: this waits for every activation or
    /// deactivation requested before it. A transition always runs to the
    /// end, even if the caller's task is cancelled in the meantime.
    func activateSession() async throws {
        try await activate(.forStarts(on: output))
    }
    
    /// The silent check before every start: brings up the session and the
    /// engine, then verifies that the signals can play on the chosen output
    /// and reports how their timing will be derived.
    ///
    /// Leaves the session active, also when a check fails; the caller
    /// deactivates it as after any start.
    func prepareForStart() async throws -> AudioPreflight {
        try await activateSession()
        
        // The start was given up while activating; nothing left to verify.
        try Task.checkCancellation()
        
        guard Signal.allCases.allSatisfy({ buffers[$0] != nil }), let gun = nodes[.go] else {
            throw PreflightError.soundMissing
        }
        
        guard ensureEngineRunning() else {
            throw PreflightError.engineNotRunning
        }
        
        guard let route = currentOutput() else {
            throw PreflightError.noOutput
        }
        
        // Forcing the speaker can fail without an error, e.g. during a call.
        if output == .iPhoneSpeaker, !route.isBuiltInSpeaker {
            throw PreflightError.speakerUnavailable(current: route.name)
        }
        
        let session = AVAudioSession.sharedInstance()
        
        guard session.sampleRate > 0, session.ioBufferDuration > 0 else {
            throw PreflightError.engineNotRunning
        }
        
        return AudioPreflight(
            sampleRate: session.sampleRate,
            ioBufferDuration: session.ioBufferDuration,
            gunTiming: timingBasis(for: .go, on: gun, applyingCalibration: true)
        )
    }
    
    private func activate(_ setup: SessionSetup) async throws {
        let previous = sessionTransition
        
        let activation = Task {
            await previous?.value
            try await self.performActivation(setup)
        }
        
        sessionTransition = Task {
            _ = try? await activation.value
        }
        
        try await activation.value
    }
    
    /// Stops the engine and releases the session so other apps may resume.
    /// Safe to call when the session is not active.
    func deactivateSession() async {
        let previous = sessionTransition
        
        let deactivation = Task {
            await previous?.value
            await self.performDeactivation()
        }
        
        sessionTransition = deactivation
        await deactivation.value
    }
    
    private func performActivation(_ setup: SessionSetup) async throws {
        let session = AVAudioSession.sharedInstance()
        
        // A session still held for another purpose (a start's, kept for the
        // music resume delay) is given back first: changing the category under
        // a running engine reconfigures it mid-flight.
        if isSessionActive, activeSetup != setup {
            await performDeactivation()
        }
        
        if setup.needsMicrophone {
            try await Self.ensureMicrophoneAccess()
        }
        
        // Before every activation, so it also holds after a media services reset.
        try await Self.configureCategory(of: session, for: setup)
        
        if setup.needsMicrophone {
            try await Self.activateWithInput(session)
        } else {
            guard try await session.activate() else {
                throw AudioSessionError.activationRefused
            }
        }
        
        if setup.forcesSpeaker {
            await Self.overrideToSpeaker(session, logger: logger)
        }

        do {
            try startEngineIfNeeded()
        } catch {
            _ = try? await session.deactivate(options: .notifyOthersOnDeactivation)
            throw error
        }
        
        isSessionActive = true
        activeSetup = setup
        activeOutputPortIDs = Self.outputPortIDs(of: session.currentRoute)
        
        timingDiagnostics.log(engine: engine, label: "Session activated")
    }
    
    private func performDeactivation() async {
        guard isSessionActive else { return }
        
        // Cleared first, so our own deactivation is never mistaken
        // for the system taking the session away.
        // The session cannot be deactivated while I/O is running.
        tearDownPlayback()
        
        do {
            _ = try await AVAudioSession.sharedInstance().deactivate(
                options: .notifyOthersOnDeactivation
            )
        } catch {
            logger.error("Could not deactivate audio session: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    /// Marks the session as gone and stops all I/O.
    private func tearDownPlayback() {
        isSessionActive = false
        activeSetup = nil
        activeOutputPortIDs = []
        
        stop()
        engine.stop()
    }
    
    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        
        engine.prepare()
        try engine.start()
    }
    
    private func attachNodes() {
        for signal in Signal.allCases {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            nodes[signal] = node
        }
    }
    
    func loadSounds(_ theme: SoundTheme) {
        stop()
        
        // Reconnecting with a possibly different format requires a stopped engine.
        let wasRunning = engine.isRunning
        if wasRunning {
            engine.stop()
        }
        
        for signal in Signal.allCases {
            let fileName = theme.assetName(for: signal)
            
            guard let node = nodes[signal] else { continue }
            
            // Dropped first: on failure play() reports the signal as missing
            // instead of playing the previous theme's sound or an unconnected node.
            buffers[signal] = nil
            onsetOffsets[signal] = nil
            
            do {
                let buffer = try SoundBufferLoader.loadBuffer(named: fileName)
                
                engine.disconnectNodeOutput(node)
                try engine.connectNode(node, to: engine.mainMixerNode, format: buffer.format)
                
                buffers[signal] = buffer
                
                let onset = AudioOnsetDetector.onsetOffset(in: buffer)
                onsetOffsets[signal] = onset
                
                logger.info(
                    """
                    Loaded \(fileName, privacy: .public): \
                    \(buffer.format.sampleRate, format: .fixed(precision: 0)) Hz, \
                    \(buffer.format.channelCount) ch, \
                    \(buffer.durationSeconds * 1000, format: .fixed(precision: 2)) ms, \
                    onset \((onset ?? -1) * 1000, format: .fixed(precision: 2)) ms
                    """
                )
            } catch {
                logger.error("Could not load \(fileName, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        
        if wasRunning {
            do {
                try startEngineIfNeeded()
            } catch {
                logger.error("Could not restart audio engine: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    @discardableResult
    func play(_ signal: Signal) -> Bool {
        guard let node = nodes[signal], let buffer = buffers[signal] else {
            logger.error("No audio player loaded for \(String(describing: signal), privacy: .public)")
            return false
        }
        
        guard ensureEngineRunning() else {
            logger.error("Audio engine not running, cannot play \(String(describing: signal), privacy: .public)")
            return false
        }
        
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        
        do {
            try node.playAudio()
        } catch {
            logger.error("Could not play \(String(describing: signal), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        
        soundEndsAt = clock.now().seconds + buffer.durationSeconds + node.outputPresentationLatency
        return true
    }
    
    /// Starts the signal on the audio clock at the given host time, or as soon
    /// after it as can still be scheduled reliably.
    ///
    /// `stop()` cancels it while it is still pending.
    func schedule(_ signal: Signal, at requested: MonotonicTimestamp) -> ScheduledSignal? {
        schedule(signal, at: requested, applyingCalibration: true)
    }
    
    /// A calibration measures against the uncorrected prediction.
    private func schedule(
        _ signal: Signal,
        at requested: MonotonicTimestamp,
        applyingCalibration: Bool
    ) -> ScheduledSignal? {
        guard let node = nodes[signal], let buffer = buffers[signal] else {
            logger.error("No audio player loaded for \(String(describing: signal), privacy: .public)")
            return nil
        }
        
        guard ensureEngineRunning() else {
            logger.error("Audio engine not running, cannot schedule \(String(describing: signal), privacy: .public)")
            return nil
        }
        
        let lead = OutputTiming.minimumLead(ioBufferDuration: AVAudioSession.sharedInstance().ioBufferDuration)
        let earliest = MonotonicTimestamp(seconds: clock.now().seconds + lead)
        let renderStart = max(requested, earliest)
        
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        
        do {
            try node.playAudio(at: clockBridge.audioTime(for: renderStart))
        } catch {
            logger.error("Could not schedule \(String(describing: signal), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        
        soundEndsAt = renderStart.seconds + buffer.durationSeconds + node.outputPresentationLatency

        return scheduledSignal(signal, on: node, renderStart: renderStart, applyingCalibration: applyingCalibration)
    }
    
    /// When the signal's playback actually started, read back from the
    /// player's render timeline. Nil until its first sample has been rendered.
    func measuredPlayback(of signal: Signal) -> ScheduledSignal? {
        guard let node = nodes[signal],
              let nodeTime = node.lastRenderTime,
              nodeTime.isHostTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime >= 0 else {
            return nil
        }
        
        // The player's sample time counts from its first rendered sample.
        let renderedAt = AVAudioTime.seconds(forHostTime: nodeTime.hostTime)
        let renderStart = renderedAt - Double(playerTime.sampleTime) / playerTime.sampleRate
        
        return scheduledSignal(
            signal,
            on: node,
            renderStart: MonotonicTimestamp(seconds: renderStart),
            applyingCalibration: true
        )
    }
    
    private func scheduledSignal(
        _ signal: Signal,
        on node: AVAudioPlayerNode,
        renderStart: MonotonicTimestamp,
        applyingCalibration: Bool
    ) -> ScheduledSignal {
        let basis = timingBasis(for: signal, on: node, applyingCalibration: applyingCalibration)
        
        let cancellationLead = OutputTiming.cancellationLead(
            ioBufferDuration: AVAudioSession.sharedInstance().ioBufferDuration
        )
        
        return ScheduledSignal(
            signal: signal,
            renderStart: renderStart,
            cancellableUntil: MonotonicTimestamp(seconds: renderStart.seconds - cancellationLead),
            audibleOnset: basis.audibleOnset(renderStart: renderStart),
            basis: basis
        )
    }
    
    private func timingBasis(
        for signal: Signal,
        on node: AVAudioPlayerNode,
        applyingCalibration: Bool
    ) -> SignalTimingBasis {
        // Zero means unknown; the session's figure is the next best estimate.
        let nodeLatency = node.outputPresentationLatency
        let latency = nodeLatency > 0 ? nodeLatency : AVAudioSession.sharedInstance().outputLatency
        
        let route = currentOutput()
        let calibration = applyingCalibration ? route.flatMap { calibrations[$0.id] } : nil
        
        let uncertainty = calibration.map { OutputTiming.uncertainty(calibrated: $0, latency: latency) }
            ?? OutputTiming.uncertainty(latency: latency, isWireless: route?.isWireless ?? false)
        
        return SignalTimingBasis(
            route: route,
            outputLatency: latency,
            onsetOffset: onsetOffsets[signal] ?? 0,
            calibration: calibration,
            uncertainty: uncertainty
        )
    }
    
    /// The output the session currently plays on, or would when activated.
    func currentOutput() -> OutputRoute? {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return nil }
        
        return OutputRoute(
            id: port.uid,
            name: port.portName,
            isWireless: OutputTiming.wirelessPorts.contains(port.portType),
            isBuiltInSpeaker: port.portType == .builtInSpeaker
        )
    }
    
    // MARK: - Calibration
    
    /// Gap between clicks: long enough for one click and its echo to fade
    /// before the next one's background noise is measured.
    private static let clickSpacing: TimeInterval = 1.0
    private static let clickLead: TimeInterval = 0.2
    
    /// Starting the microphone can reconfigure the hardware (Bluetooth
    /// outputs run at a different sample rate than the microphone), which
    /// stops the playback engine. Once audio arrives, this much longer.
    private static let recorderSettleTime: TimeInterval = 0.3
    private static let recorderStartTimeout: TimeInterval = 2
    
    /// How long after its predicted onset a click is still searched for.
    /// Covers the delay of a slow wireless output without reaching the next click.
    private static let clickSearchDuration: TimeInterval = 0.5
    
    /// Background noise is measured in this stretch before a click renders,
    /// relative to its render start.
    private static let noiseWindow: ClosedRange<TimeInterval> = -0.15 ... -0.02
    
    /// Plays the gun several times on the current output, records it with the
    /// built-in microphone and compares when it was heard with the prediction.
    ///
    /// Activates and deactivates the session itself; don't call during a start.
    func calibrateCurrentOutput() async throws -> OutputCalibration {
        try await activate(.forCalibration(on: output))
        
        do {
            let calibration = try await measureCalibration()
            await deactivateSession()
            return calibration
        } catch {
            await deactivateSession()
            throw error
        }
    }
    
    private func measureCalibration() async throws -> OutputCalibration {
        guard let route = currentOutput() else {
            throw CalibrationError.recordingFailed("no output")
        }
        
        let recorder = MicrophoneRecorder()
        
        do {
            try recorder.start()
        } catch let error as CalibrationError {
            throw error
        } catch {
            throw CalibrationError.recordingFailed(error.localizedDescription)
        }
        
        var clicks: [ScheduledSignal] = []
        
        do {
            let deadline = clock.now().seconds + Self.recorderStartTimeout
            while !recorder.isReceivingAudio {
                guard clock.now().seconds < deadline else {
                    throw CalibrationError.recordingFailed("the microphone delivered no audio")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .seconds(Self.recorderSettleTime))

            for index in 0..<(CalibrationMath.warmUpClicks + CalibrationMath.clickCount) {
                guard ensureEngineRunning() else {
                    throw CalibrationError.playbackFailed("the audio engine could not restart")
                }
                
                let at = MonotonicTimestamp(seconds: clock.now().seconds + Self.clickLead)
                
                guard let click = schedule(.go, at: at, applyingCalibration: false) else {
                    throw CalibrationError.playbackFailed("scheduling failed (engine running: \(engine.isRunning))")
                }
                
                if index >= CalibrationMath.warmUpClicks {
                    clicks.append(click)
                }
                
                try await Task.sleep(for: .seconds(Self.clickSpacing))
            }
        } catch {
            _ = recorder.stop()
            throw error
        }
        
        let recording = recorder.stop()
        
        guard currentOutput()?.id == route.id else {
            throw CalibrationError.outputChanged
        }
        
        let offsets = clicks.compactMap { click -> TimeInterval? in
            let render = click.renderStart.seconds
            let predicted = click.audibleOnset.best.seconds
            
            guard let heard = CalibrationMath.onset(
                in: recording,
                window: render...(predicted + Self.clickSearchDuration),
                noiseWindow: (render + Self.noiseWindow.lowerBound)...(render + Self.noiseWindow.upperBound)
            ) else { return nil }
            
            return heard - recorder.inputLatency - predicted
        }
        
        let listed = offsets.map { String(format: "%.1f", $0 * 1000) }.joined(separator: ", ")
        logger.info("Calibration clicks on \(route.name, privacy: .public): \(listed, privacy: .public) ms")
        
        let summary = try CalibrationMath.summarize(offsets: offsets)
        
        logger.info(
            "Calibrated \(route.name, privacy: .public): \(summary.correction * 1000, format: .fixed(precision: 1)) ms ±\(summary.uncertainty * 1000, format: .fixed(precision: 1)) ms from \(offsets.count) clicks"
        )
        
        return OutputCalibration(
            routeID: route.id,
            routeName: route.name,
            isBuiltInSpeaker: route.isBuiltInSpeaker,
            correction: summary.correction,
            uncertainty: summary.uncertainty,
            clickCount: offsets.count,
            date: .now,
            reportedLatency: clicks.first?.basis.outputLatency
        )
    }
    
    func stop() {
        for node in nodes.values {
            node.stop()
        }
        soundEndsAt = nil
    }
    
    /// A hardware reconfiguration (e.g. a Bluetooth route settling right after
    /// activation) stops the engine; while the session is active it can simply
    /// be started again.
    private func ensureEngineRunning() -> Bool {
        guard !engine.isRunning else { return true }
        guard isSessionActive else { return false }
        
        logger.notice("Audio engine was stopped, restarting")
        
        do {
            try startEngineIfNeeded()
        } catch {
            logger.error("Could not restart audio engine: \(error.localizedDescription, privacy: .public)")
        }
        return engine.isRunning
    }
    
    func playRecall(times: Int, gap: TimeInterval) async {
        guard times > 0 else { return }
        
        for index in 0..<times {
            guard !Task.isCancelled else { return }
            guard play(.go) else { return }
            
            // Wait for the sound to actually finish before waiting a short interval
            let waitTime = index == times - 1 ? duration(of: .go) : gap
            
            do {
                try await Task.sleep(for: .seconds(waitTime))
            } catch {
                return
            }
        }
    }
    
    func duration(of signal: Signal) -> TimeInterval {
        buffers[signal]?.durationSeconds ?? 0
    }
    
    private func observeSystemNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        
        // The async messages may be posted on any thread; the handlers hop to the main actor.
        observerTokens = [
            center.addObserver(of: session, for: AVAudioSession.RouteDidChangeMessage.self) { [weak self] _ in
                await self?.handleRouteChange()
            },
            
            // Since iOS 27 this also covers interruptions (calls, alarms),
            // which replaces observing interruptionNotification.
            center.addObserver(for: AVAudioSession.DidBecomeInactiveMessage.self) { [weak self] _ in
                self?.handleSessionBecameInactive()
            },
            
            center.addObserver(of: session, for: AVAudioSession.MediaServicesWereResetMessage.self) { [weak self] _ in
                await self?.handleMediaServicesReset()
            },
            
            center.addObserver(for: AVAudioEngine.ConfigurationDidChangeMessage.self) { [weak self] message in
                await self?.handleEngineConfigurationChange(senderID: message.engineID)
            },
        ]
    }
    
    private func handleRouteChange() {
        onRouteChange?()
        
        guard isSessionActive else { return }
        
        let route = AVAudioSession.sharedInstance().currentRoute
        let current = Self.outputPortIDs(of: route)
        
        // Route notifications also fire for category changes
        // Only different set of output ports are relevant
        guard current != activeOutputPortIDs else { return }
        
        let names = route.outputs.map(\.portName).joined(separator: ", ")
        let outputs = names.isEmpty ? String(localized: "none") : names
        
        reportUnexpectedStop(
            String(localized: "The start was aborted because the audio output changed (now: \(outputs)).")
        )
    }
    
    /// Internal so tests can call it: the system's notification carries a
    /// deactivation context that can't be constructed outside AVFAudio.
    func handleSessionBecameInactive() {
        guard isSessionActive else { return }
        
        tearDownPlayback()
        
        reportUnexpectedStop(
            String(localized: "The start was aborted because the system deactivated audio (e.g. a call or an alarm).")
        )
    }
    
    private func handleEngineConfigurationChange(senderID: ObjectIdentifier?) {
        guard senderID == ObjectIdentifier(engine) else { return }
        
        logger.notice("Audio engine configuration changed, engine running: \(self.engine.isRunning)")
        
        // Only a stopped engine is a problem. If it is running, playback was not affected.
        guard isSessionActive, !engine.isRunning else { return }
        
        // A sound that was playing or scheduled is gone with the stopped engine.
        let cutOffSound = soundEndsAt.map { clock.now().seconds < $0 } ?? false
        let restarted = ensureEngineRunning()
        
        guard cutOffSound || !restarted else { return }
        
        reportUnexpectedStop(
            String(localized: "The start was aborted because the audio system was reconfigured.")
        )
    }
    
    private func handleMediaServicesReset() {
        logger.error("Media services were reset, rebuilding audio engine")
        
        let wasActive = isSessionActive
        
        // treat all audio objects as invalid
        tearDownPlayback()
        
        engine = AVAudioEngine()
        nodes.removeAll()
        attachNodes()
        loadSounds(theme)
        
        if wasActive {
            reportUnexpectedStop(String(localized: "The start was aborted because the audio system was reset."))
        }
    }
    
    private func reportUnexpectedStop(_ message: String) {
        logger.error("\(message, privacy: .public)")
        onUnexpectedStop?(message)
    }
    
    private static func outputPortIDs(
        of route: AVAudioSessionRouteDescription
    ) -> [String] {
        route.outputs.map(\.uid).sorted()
    }
}

nonisolated enum Signal: CaseIterable, Sendable {
    case onYourMarks
    case set
    case go
}

@MainActor
protocol SignalPlayer {
    @discardableResult
    func play(_ signal: Signal) -> Bool
    
    func schedule(_ signal: Signal, at time: MonotonicTimestamp) -> ScheduledSignal?
    
    func measuredPlayback(of signal: Signal) -> ScheduledSignal?
    
    func stop()
    
    func playRecall(times: Int, gap: TimeInterval) async
    
    func duration(of signal: Signal) -> TimeInterval
    
    func logTimingDiagnostics(label: String)
    
    /// Makes everything ready for a start and reports the output's timing.
    /// Silent; may take a moment, e.g. while a Bluetooth output wakes up.
    func prepareForStart() async throws -> AudioPreflight
}

/// A signal player that also owns the audio session, as the view model needs it.
@MainActor
protocol AudioSessionPlayer: AnyObject, SignalPlayer {
    var theme: SoundTheme { get set }
    var output: AudioOutput { get set }
    var calibrations: [String: OutputCalibration] { get set }
    
    /// Audio output can't be trusted anymore; argument shown to the user
    var onUnexpectedStop: ((String) -> Void)? { get set }
    var onRouteChange: (() -> Void)? { get set }
    
    func activateSession() async throws
    
    func deactivateSession() async
    
    func currentOutput() -> OutputRoute?
    
    func calibrateCurrentOutput() async throws -> OutputCalibration
}

nonisolated enum AudioSessionError: LocalizedError {
    case activationRefused
    case microphoneDenied
    
    var errorDescription: String? {
        switch self {
        case .activationRefused:
            String(localized: "The system did not activate the audio session.")
        case .microphoneDenied:
            String(localized: "The iPhone speaker and calibration need microphone access. You can allow it in Settings.")
        }
    }
}

// Typed forms of the notifications the SDK doesn't offer messages for yet.

extension AVAudioSession {
    nonisolated struct RouteDidChangeMessage: NotificationCenter.AsyncMessage {
        typealias Subject = AVAudioSession
        
        static var name: Notification.Name { AVAudioSession.routeChangeNotification }
        
        static func makeMessage(_ notification: Notification) -> Self? { Self() }
    }
    
    nonisolated struct MediaServicesWereResetMessage: NotificationCenter.AsyncMessage {
        typealias Subject = AVAudioSession
        
        static var name: Notification.Name { AVAudioSession.mediaServicesWereResetNotification }
        
        static func makeMessage(_ notification: Notification) -> Self? { Self() }
    }
}

extension AVAudioEngine {
    nonisolated struct ConfigurationDidChangeMessage: NotificationCenter.AsyncMessage {
        typealias Subject = AVAudioEngine
        
        /// The engine that changed. Observed without a subject, because
        /// the engine is replaced when media services are reset.
        let engineID: ObjectIdentifier?
        
        static var name: Notification.Name { .AVAudioEngineConfigurationChange }
        
        static func makeMessage(_ notification: Notification) -> Self? {
            Self(engineID: (notification.object as AnyObject?).map(ObjectIdentifier.init))
        }
    }
}
