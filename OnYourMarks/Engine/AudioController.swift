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
    
    private var engine = AVAudioEngine()
    private var nodes: [Signal: AVAudioPlayerNode] = [:]
    private var buffers: [Signal: AVAudioPCMBuffer] = [:]
    
    /// Offsets for the audible transient
    private(set) var onsetOffsets: [Signal: TimeInterval] = [:]
    
    private(set) var isSessionActive = false
    
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
    @concurrent
    private nonisolated static func configureCategory(of session: AVAudioSession, logger: Logger) async {
        do {
            try session.setCategory(.playback, mode: .default, options: [])
        } catch {
            logger.error("Could not set audio session category: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    func logTimingDiagnostics(label: String) {
        timingDiagnostics.log(engine: engine.isRunning ? engine : nil, label: label)
    }
    
    /// Activates the session and starts the engine.
    ///
    /// Transitions are serialized: this waits for every activation or
    /// deactivation requested before it. A transition always runs to the
    /// end, even if the caller's task is cancelled in the meantime.
    func activateSession() async throws {
        let previous = sessionTransition
        
        let activation = Task {
            await previous?.value
            try await self.performActivation()
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
    
    private func performActivation() async throws {
        let session = AVAudioSession.sharedInstance()
        
        // Before every activation, so it also holds after a media services reset.
        await Self.configureCategory(of: session, logger: logger)
        
        guard try await session.activate() else {
            throw AudioSessionError.activationRefused
        }
        
        do {
            try startEngineIfNeeded()
        } catch {
            _ = try? await session.deactivate(options: .notifyOthersOnDeactivation)
            throw error
        }
        
        isSessionActive = true
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
        
        guard engine.isRunning else {
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
        
        return true
    }
    
    /// Starts the signal on the audio clock at the given host time, or as soon
    /// after it as can still be scheduled reliably.
    ///
    /// `stop()` cancels it while it is still pending.
    func schedule(_ signal: Signal, at requested: MonotonicTimestamp) -> ScheduledSignal? {
        guard let node = nodes[signal], let buffer = buffers[signal] else {
            logger.error("No audio player loaded for \(String(describing: signal), privacy: .public)")
            return nil
        }
        
        guard engine.isRunning else {
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
        
        return scheduledSignal(signal, on: node, renderStart: renderStart)
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
        
        return scheduledSignal(signal, on: node, renderStart: MonotonicTimestamp(seconds: renderStart))
    }
    
    private func scheduledSignal(
        _ signal: Signal,
        on node: AVAudioPlayerNode,
        renderStart: MonotonicTimestamp
    ) -> ScheduledSignal {
        let session = AVAudioSession.sharedInstance()
        
        // Zero means unknown; the session's figure is the next best estimate.
        let nodeLatency = node.outputPresentationLatency
        let latency = nodeLatency > 0 ? nodeLatency : session.outputLatency
        
        let isWireless = session.currentRoute.outputs.contains {
            OutputTiming.wirelessPorts.contains($0.portType)
        }
        
        return ScheduledSignal(
            signal: signal,
            renderStart: renderStart,
            audibleOnset: OutputTiming.audibleOnset(
                renderStart: renderStart,
                latency: latency,
                onsetOffset: onsetOffsets[signal] ?? 0,
                uncertainty: OutputTiming.uncertainty(latency: latency, isWireless: isWireless)
            )
        )
    }
    
    func stop() {
        for node in nodes.values {
            node.stop()
        }
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
        guard isSessionActive else { return }
        
        let route = AVAudioSession.sharedInstance().currentRoute
        let current = Self.outputPortIDs(of: route)
        
        // Route notifications also fire for category changes
        // Only different set of output ports are relevant
        guard current != activeOutputPortIDs else { return }
        
        let outputs = route.outputs.map(\.portName).joined(separator: ", ")
        
        reportUnexpectedStop(
            "The start was aborted because the audio output changed (now : \(outputs.isEmpty ? "none" : outputs))."
        )
    }
    
    /// Internal so tests can call it: the system's notification carries a
    /// deactivation context that can't be constructed outside AVFAudio.
    func handleSessionBecameInactive() {
        guard isSessionActive else { return }
        
        tearDownPlayback()
        
        reportUnexpectedStop("The start was aborted because the system deactivated audio (e.g. a call or an alarm).")
    }
    
    private func handleEngineConfigurationChange(senderID: ObjectIdentifier?) {
        guard senderID == ObjectIdentifier(engine) else { return }
        
        logger.notice("Audio engine configuration changed, engine running: \(self.engine.isRunning)")
        
        // only stopped engine is a problem. If it is running, playback was not affected
        guard isSessionActive, !engine.isRunning else { return }
        
        reportUnexpectedStop(
            "The start was aborted because the audio system was reconfigured."
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
            reportUnexpectedStop("The start was aborted because the audio system was reset.")
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
}

/// A signal player that also owns the audio session, as the view model needs it.
@MainActor
protocol AudioSessionPlayer: AnyObject, SignalPlayer {
    var theme: SoundTheme { get set }
    
    /// Audio output can't be trusted anymore; argument shown to the user
    var onUnexpectedStop: ((String) -> Void)? { get set }
    
    func activateSession() async throws
    
    func deactivateSession() async
}

nonisolated enum AudioSessionError: LocalizedError {
    case activationRefused
    
    var errorDescription: String? {
        switch self {
        case .activationRefused:
            return "The system did not activate the audio session."
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
