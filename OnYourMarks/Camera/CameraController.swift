//
//  CameraController.swift
//  OnYourMarks
//

import AVFoundation
import ImageIO
import OSLog
import Synchronization

/// Owns the capture session: picks the format, switches between the idle and
/// the precision frame rate, watches system pressure and hands every frame,
/// with its capture time, to whoever analyses it.
///
/// In the precision window it checks that the rate arrives, restarts the
/// session once if it does not, and holds exposure, focus and white balance
/// (`PrecisionWindowMonitor`). It notices when frames stop, whatever the reason.
@Observable
final class CameraController: FrameSource {
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks",
        category: "Camera"
    )

    let session = AVCaptureSession()

    private(set) var mode: CameraMode = .idle
    private(set) var pressure: CameraPressureLevel = .nominal
    private(set) var isInterrupted = false

    /// The format chosen at configuration, kept for the session's life.
    private(set) var format: CameraFormatDescriptor?

    /// The rate of the precision mode. The format is chosen to reach it; a
    /// camera that can't runs at the fastest rate it has.
    private(set) var precisionFrameRate = CameraFrameRatePolicy.precision

    /// Frames of the most recent precision window.
    private(set) var lastPrecisionStatistics: FrameStatistics?

    /// Why frames stopped arriving, until they arrive again.
    private(set) var fault: CameraFault?

    /// Whether a frame has arrived since the camera was started, and the
    /// flow has not stopped since.
    private(set) var isReceivingFrames = false

    /// Exposure, focus and white balance are held for the open precision
    /// window, which has its rate or has given up on it.
    private(set) var isSteady = false

    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var isStarted = false

    /// Whether frames are arriving: not before the first one after `start()`,
    /// not while the system has taken the camera away, not after they stopped.
    var isDelivering: Bool {
        isStarted && fault == nil && isReceivingFrames
    }

    var condition: CameraCondition {
        guard isStarted else { return .off }

        if let fault {
            return .failed(fault)
        }
        guard isReceivingFrames else { return .starting }

        return .delivering(isSteady: mode == .precision && isSteady)
    }

    /// How the precision rate will come out with the chosen format.
    var setup: CameraSetup? {
        format.map {
            CameraSetup(
                width: $0.width,
                height: $0.height,
                requestedFrameRate: precisionFrameRate,
                expectedFrameRate: CameraFrameRatePolicy.supported(precisionFrameRate, in: $0.frameRateRanges) ?? $0.maxFrameRate
            )
        }
    }

    /// What a start needs to know about the camera, on the main actor.
    @ObservationIgnored var onReport: ((CameraReport) -> Void)?

    @ObservationIgnored private var device: AVCaptureDevice?

    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let receiver = FrameReceiver()
    @ObservationIgnored private let frameQueue = DispatchSerialQueue(label: "camera.frame")
    @ObservationIgnored private let sessionQueue = DispatchSerialQueue(label: "camera.session")

    /// Looks at the flow of frames and the precision window on the session
    /// queue, while the camera runs.
    @ObservationIgnored private var watchdog: DispatchSourceTimer?

    /// Counts precision windows, so news from a closed one is not taken
    /// for the next.
    @ObservationIgnored private var windowGeneration = 0

    /// The deadlines of the precision window and the stall timeout are kept
    /// to within this. Each look reads a handful of device properties.
    nonisolated static let watchdogInterval: TimeInterval = 0.02

    @ObservationIgnored private let stateReport = CameraStateReport()
    @ObservationIgnored private var pressureObservation: NSKeyValueObservation?
    @ObservationIgnored private var observerTokens: [NotificationCenter.ObservationToken] = []

    isolated deinit {
        pressureObservation?.invalidate()
        watchdog?.cancel()

        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Configuration

    func configureIfNeeded() -> Bool {
        if isConfigured { return true }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            logger.error("No back camera available")
            return false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            return false
        }
        session.addInput(input)

        videoOutput.setSampleBufferDelegate(receiver, queue: frameQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true

        guard session.canAddOutput(videoOutput) else {
            session.removeInput(input)
            return false
        }
        session.addOutput(videoOutput)

        // After adding the input, which resets the device's frame durations.
        // Here on the main actor: nothing runs on the session queue yet.
        format = Self.selectFormat(
            on: camera,
            precision: precisionFrameRate,
            frameRate: CameraFrameRatePolicy.idle,
            logger: logger
        )

        receiver.setSynchronizationClock(session.synchronizationClock)
        receiver.setNewsHandler(Self.newsHandler(for: self))
        device = camera
        isConfigured = true

        observePressure(of: camera)
        observeSession()
        return true
    }

    /// Built outside the main actor: it is called on the capture and the
    /// session queue.
    private nonisolated static func newsHandler(for controller: CameraController) -> @Sendable (CameraNews) -> Void {
        { [weak controller] news in
            Task { @MainActor in
                controller?.handle(news)
            }
        }
    }

    /// Picks the format that reaches the precision rate and sets the given
    /// rate within it. Returns the format the device has afterwards.
    ///
    /// Called where the device is configured: on the main actor before the
    /// session first runs, on the session queue from then on.
    private nonisolated static func selectFormat(
        on camera: AVCaptureDevice,
        precision: Double,
        frameRate: Double,
        logger: Logger
    ) -> CameraFormatDescriptor? {
        let formats = camera.formats
        let descriptors = formats.map(CameraFormatDescriptor.init)

        guard let index = CameraFormatSelector.bestIndex(among: descriptors, frameRate: precision) else {
            logger.error("The camera offers no formats")
            return nil
        }

        let chosen = descriptors[index]

        do {
            try camera.lockForConfiguration()
            camera.activeFormat = formats[index]
            setFrameRate(frameRate, on: camera)
            camera.unlockForConfiguration()
        } catch {
            logger.error("Could not select the camera format: \(error.localizedDescription, privacy: .public)")
            return CameraFormatDescriptor(camera.activeFormat)
        }

        logger.info(
            """
            Camera format \(chosen.width)x\(chosen.height), up to \
            \(chosen.maxFrameRate, format: .fixed(precision: 0)) fps, \
            auto low-light frame rate \(chosen.supportsAutoFrameRate ? "supported" : "unsupported", privacy: .public) \
            (of \(formats.count) formats)
            """
        )

        if chosen.maxFrameRate < precision {
            logger.notice("No format reaches \(precision, format: .fixed(precision: 0)) fps")
        }
        return chosen
    }

    /// Changes the precision rate. A configured camera picks its format
    /// anew, which interrupts a running stream for a moment, so this is for
    /// settings, not for a start in progress.
    ///
    /// The format changes on the session queue, in line with starting,
    /// stopping and the frame rates, and off the main actor, which a format
    /// change would hold up. `format` follows once it is done.
    func setPrecisionFrameRate(_ frameRate: Double) {
        guard frameRate != precisionFrameRate else { return }

        precisionFrameRate = frameRate

        guard isConfigured, let device else { return }

        let modeRate = CameraFrameRatePolicy.frameRate(for: mode, pressure: pressure, precision: frameRate)

        // Neither is Sendable; from here on both are only configured on
        // the serial session queue.
        nonisolated(unsafe) let captureDevice = device
        nonisolated(unsafe) let session = self.session
        let logger = self.logger

        sessionQueue.async { [weak self] in
            session.beginConfiguration()
            let chosen = Self.selectFormat(on: captureDevice, precision: frameRate, frameRate: modeRate, logger: logger)
            session.commitConfiguration()

            Task { @MainActor in
                // A later change may have overtaken this one.
                guard let self, self.precisionFrameRate == frameRate else { return }

                self.format = chosen
                self.reportState()
            }
        }
    }

    // MARK: - Running

    func start() {
        guard isConfigured, !isStarted else { return }
        isStarted = true
        isReceivingFrames = false
        fault = nil

        // AVCaptureSession isn't Sendable; it only starts and stops on the
        // serial session queue, after its configuration on the main actor.
        nonisolated(unsafe) let session = self.session

        sessionQueue.async {
            guard !session.isRunning else { return }
            session.startRunning()
        }

        startWatchdog()
        reportState()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        isReceivingFrames = false
        isSteady = false
        fault = nil

        watchdog?.cancel()
        watchdog = nil
        receiver.interruptFlow()

        nonisolated(unsafe) let session = self.session

        sessionQueue.async {
            guard session.isRunning else { return }
            session.stopRunning()
        }

        reportState()
    }

    /// Receives every frame on the capture queue. A slow handler makes the
    /// camera drop the frames that arrive meanwhile.
    func setFrameHandler(_ handler: (@Sendable (CameraFrame) -> Void)?) {
        receiver.setHandler(handler)
    }

    /// Receives every frame after the frame handler, on the capture queue.
    func setRecordingHandler(_ handler: (@Sendable (CameraFrame) -> Void)?) {
        receiver.setRecorder(handler)
    }

    /// Frames since the mode last changed.
    func currentStatistics() -> FrameStatistics {
        receiver.statistics()
    }

    /// What the open precision window has delivered since its rate was
    /// decided. Nil outside the window.
    func precisionDelivery() -> PrecisionRateDelivery? {
        guard mode == .precision else { return nil }
        return receiver.windowDelivery()
    }

    // MARK: - Frame rate

    func setMode(_ newMode: CameraMode) {
        guard newMode != mode else { return }

        let statistics = receiver.resetStatistics()

        if mode == .precision {
            lastPrecisionStatistics = statistics
            log(statistics)
        }

        mode = newMode
        isSteady = false

        if newMode == .precision {
            windowGeneration += 1
        }

        applyMode()
        reportState()
    }

    /// Opens or closes the precision window on the session queue: the rate,
    /// the cap on the exposure, and at the end the automatic settings again.
    private func applyMode() {
        guard let device else { return }

        let mode = self.mode
        let requested = precisionFrameRate
        let frameRate = CameraFrameRatePolicy.frameRate(for: mode, pressure: pressure, precision: requested)
        let generation = windowGeneration

        // AVCaptureDevice isn't Sendable; it is only reconfigured on the
        // serial session queue.
        nonisolated(unsafe) let captureDevice = device
        let receiver = self.receiver
        let logger = self.logger

        sessionQueue.async {
            Self.apply(
                mode,
                frameRate: frameRate,
                requested: requested,
                generation: generation,
                on: captureDevice,
                receiver: receiver,
                logger: logger
            )
        }
    }

    private nonisolated static func apply(
        _ mode: CameraMode,
        frameRate: Double,
        requested: Double,
        generation: Int,
        on device: AVCaptureDevice,
        receiver: FrameReceiver,
        logger: Logger
    ) {
        do {
            try device.lockForConfiguration()
        } catch {
            logger.error("Frame-rate config failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        defer { device.unlockForConfiguration() }

        let applied = setFrameRate(frameRate, on: device) ?? frameRate

        switch mode {
        case .precision:
            let cap = CaptureSettingsPolicy.maximumExposure(
                frameRate: applied,
                supported: device.activeFormat.minExposureDuration...device.activeFormat.maxExposureDuration
            )
            device.activeMaxExposureDuration = cap ?? .invalid

            receiver.openWindow(
                PrecisionWindowMonitor(
                    requested: requested,
                    expected: applied,
                    openedAt: CACurrentMediaTime(),
                    maximumExposure: cap?.seconds
                ),
                generation: generation
            )

        case .idle:
            receiver.closeWindow()
            device.activeMaxExposureDuration = .invalid
            setModes(CaptureSettingsPolicy.modes(.continuous, supported: support(of: device)), on: device)
        }
    }

    /// Only the rate, for a change of pressure: the window stays as it is.
    private func applyFrameRate() {
        guard let device else { return }

        let frameRate = CameraFrameRatePolicy.frameRate(for: mode, pressure: pressure, precision: precisionFrameRate)

        // AVCaptureDevice isn't Sendable; it is only reconfigured on the
        // serial session queue.
        nonisolated(unsafe) let captureDevice = device
        let logger = self.logger

        sessionQueue.async {
            do {
                try captureDevice.lockForConfiguration()
                Self.setFrameRate(frameRate, on: captureDevice)
                captureDevice.unlockForConfiguration()
            } catch {
                logger.error("Frame-rate config failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Fixes the rate by setting both bounds and returns the rate set. The
    /// device must be locked.
    ///
    /// The automatic low-light frame rate stays off: it would take the rate
    /// out of our hands, and setting a duration while it is on raises an exception.
    @discardableResult
    private nonisolated static func setFrameRate(_ requested: Double, on device: AVCaptureDevice) -> Double? {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate }

        guard let frameRate = CameraFrameRatePolicy.supported(requested, in: ranges) else { return nil }

        let frameDuration = CMTime(seconds: 1 / frameRate, preferredTimescale: 60_000)

        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        return frameRate
    }

    private func log(_ statistics: FrameStatistics) {
        logger.info(
            """
            Precision window: \(statistics.delivered) frames at \
            \(statistics.deliveredFrameRate ?? 0, format: .fixed(precision: 1)) fps, \
            longest gap \(statistics.longestGap * 1000, format: .fixed(precision: 1)) ms, \
            dropped \(statistics.dropped) (\(statistics.droppedLate) late, \
            \(statistics.droppedOutOfBuffers) out of buffers, \
            \(statistics.droppedDiscontinuity) discontinuity), \
            pressure \(String(describing: self.pressure), privacy: .public)
            """
        )
    }

    // MARK: - Precision window

    private func startWatchdog() {
        guard let device else { return }

        watchdog?.cancel()
        watchdog = Self.makeWatchdog(
            on: sessionQueue,
            device: device,
            session: session,
            receiver: receiver,
            logger: logger
        )
    }

    /// Built outside the main actor: its handler runs on the session queue,
    /// where the device and the session are configured anyway.
    private nonisolated static func makeWatchdog(
        on queue: DispatchSerialQueue,
        device: AVCaptureDevice,
        session: AVCaptureSession,
        receiver: FrameReceiver,
        logger: Logger
    ) -> DispatchSourceTimer {
        // Neither is Sendable; both are only touched on the session queue.
        nonisolated(unsafe) let device = device
        nonisolated(unsafe) let session = session

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)

        timer.setEventHandler {
            let exposure = PrecisionWindowMonitor.Exposure(
                isAdjusting: device.isAdjustingExposure || device.isAdjustingFocus || device.isAdjustingWhiteBalance,
                duration: device.exposureDuration.seconds
            )

            guard let (step, window) = receiver.tick(at: CACurrentMediaTime(), exposure: exposure) else { return }

            switch step.action {
            case .restart:
                logger.notice(
                    "Precision rate \(window.expectedFrameRate, format: .fixed(precision: 0)) fps did not arrive; restarting the session"
                )
                restart(session, at: window.expectedFrameRate, on: device, receiver: receiver, logger: logger)

            case .lock(let hasSettled):
                let settings = lockSettings(on: device, hasSettled: hasSettled, maximumExposure: window.maximumExposure, logger: logger)
                receiver.sendLocked(settings)

            case nil:
                break
            }
        }

        timer.resume()
        return timer
    }

    /// A session started at the precision rate delivered it when a running
    /// one did not. The device stays locked across the start, so the session
    /// takes the durations as they are.
    private nonisolated static func restart(
        _ session: AVCaptureSession,
        at frameRate: Double,
        on device: AVCaptureDevice,
        receiver: FrameReceiver,
        logger: Logger
    ) {
        let began = CACurrentMediaTime()
        session.stopRunning()

        do {
            try device.lockForConfiguration()
            setFrameRate(frameRate, on: device)
            session.startRunning()
            device.unlockForConfiguration()
        } catch {
            logger.error("Could not lock the camera for the restart: \(error.localizedDescription, privacy: .public)")
            session.startRunning()
        }

        receiver.restarted(began: began, finished: CACurrentMediaTime())
    }

    /// Holds exposure, focus and white balance where they are, as far as
    /// the device can, and returns what is held.
    private nonisolated static func lockSettings(
        on device: AVCaptureDevice,
        hasSettled: Bool,
        maximumExposure: TimeInterval?,
        logger: Logger
    ) -> CaptureSettings {
        do {
            try device.lockForConfiguration()
            setModes(CaptureSettingsPolicy.modes(.locked, supported: support(of: device)), on: device)
            device.unlockForConfiguration()
        } catch {
            logger.error("Could not lock exposure, focus and white balance: \(error.localizedDescription, privacy: .public)")
        }

        return CaptureSettings(
            exposureDuration: device.exposureDuration.seconds,
            iso: Double(device.iso),
            maximumExposureDuration: maximumExposure,
            isExposureLocked: device.exposureMode == .locked,
            isFocusLocked: device.focusMode == .locked,
            isWhiteBalanceLocked: device.whiteBalanceMode == .locked,
            hadSettled: hasSettled
        )
    }

    private nonisolated static func support(of device: AVCaptureDevice) -> CaptureSettingsPolicy.Support {
        let adjustments: [CaptureSettingsPolicy.Adjustment] = [.locked, .continuous]

        return CaptureSettingsPolicy.Support(
            exposure: Set(adjustments.filter { device.isExposureModeSupported(exposureMode(for: $0)) }),
            focus: Set(adjustments.filter { device.isFocusModeSupported(focusMode(for: $0)) }),
            whiteBalance: Set(adjustments.filter { device.isWhiteBalanceModeSupported(whiteBalanceMode(for: $0)) })
        )
    }

    /// Only modes the policy found supported; the device must be locked.
    private nonisolated static func setModes(_ modes: CaptureSettingsPolicy.Modes, on device: AVCaptureDevice) {
        if let exposure = modes.exposure {
            device.exposureMode = exposureMode(for: exposure)
        }
        if let focus = modes.focus {
            device.focusMode = focusMode(for: focus)
        }
        if let whiteBalance = modes.whiteBalance {
            device.whiteBalanceMode = whiteBalanceMode(for: whiteBalance)
        }
    }

    private nonisolated static func exposureMode(for adjustment: CaptureSettingsPolicy.Adjustment) -> AVCaptureDevice.ExposureMode {
        adjustment == .locked ? .locked : .continuousAutoExposure
    }

    private nonisolated static func focusMode(for adjustment: CaptureSettingsPolicy.Adjustment) -> AVCaptureDevice.FocusMode {
        adjustment == .locked ? .locked : .continuousAutoFocus
    }

    private nonisolated static func whiteBalanceMode(for adjustment: CaptureSettingsPolicy.Adjustment) -> AVCaptureDevice.WhiteBalanceMode {
        adjustment == .locked ? .locked : .continuousAutoWhiteBalance
    }

    private func handle(_ news: CameraNews) {
        guard isStarted else { return }

        switch news {
        case .flow(.began):
            let recovered = fault != nil
            isReceivingFrames = true
            fault = nil

            if recovered {
                logger.notice("Frames are arriving again")
            }
            onReport?(.delivering)
            reportState()

        case .flow(.stopped(let lastFrame)):
            isReceivingFrames = false

            guard fault == nil else { return }

            logger.error("No frame for \(FrameFlow.stallTimeout, format: .fixed(precision: 1)) s")
            fault = .framesStopped
            onReport?(.failed(.framesStopped, lastFrame: lastFrame.map(MonotonicTimestamp.init(seconds:))))
            reportState()

        case .precisionRate(let report, let generation):
            guard mode == .precision, generation == windowGeneration else { return }

            logger.info(
                """
                Precision rate \(report.outcome.rawValue, privacy: .public) \
                \((report.delay ?? 0) * 1000, format: .fixed(precision: 0)) ms after it was asked for
                """
            )
            onReport?(.precisionRate(report))

        case .restarted(let generation):
            guard mode == .precision, generation == windowGeneration else { return }

            onReport?(.restarted)

        case .locked(let settings, let generation):
            guard mode == .precision, generation == windowGeneration else { return }

            logger.info(
                """
                Exposure \(settings.exposureDuration * 1000, format: .fixed(precision: 2)) ms, \
                ISO \(settings.iso, format: .fixed(precision: 0)) held\
                \(settings.hadSettled ? "" : " before it had settled", privacy: .public)
                """
            )
            isSteady = true
            onReport?(.settingsLocked(settings))
        }
    }

    // MARK: - System pressure

    private func observePressure(of camera: AVCaptureDevice) {
        pressureObservation = camera.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
            let level = CameraPressureLevel(device.systemPressureState.level)

            Task { @MainActor in
                self?.handlePressure(level)
            }
        }
    }

    private func handlePressure(_ level: CameraPressureLevel) {
        guard level != pressure else { return }

        pressure = level
        logger.notice("System pressure is now \(String(describing: level), privacy: .public)")

        if mode == .precision, level >= .serious {
            logger.notice("Keeping the precision frame rate despite the pressure")
        }

        // Only changes the rate outside the precision window.
        applyFrameRate()
        stateReport.update(pressure: level, droppedFrames: receiver.statistics().dropped)
    }

    // MARK: - Session events

    private func observeSession() {
        let center = NotificationCenter.default

        observerTokens = [
            center.addObserver(of: session, for: AVCaptureSession.WasInterruptedMessage.self) { [weak self] message in
                await self?.handleInterruption(reason: message.reason)
            },
            center.addObserver(of: session, for: AVCaptureSession.InterruptionEndedMessage.self) { [weak self] _ in
                await self?.handleInterruptionEnded()
            },
            center.addObserver(of: session, for: AVCaptureSession.RuntimeErrorMessage.self) { [weak self] message in
                await self?.handleRuntimeError(message)
            },
        ]
    }

    private func handleInterruption(reason: Int?) {
        logger.notice("Camera interrupted, reason \(reason ?? -1)")

        isInterrupted = true
        fail(.interrupted(reason: reason))
    }

    private func handleInterruptionEnded() {
        logger.notice("Camera interruption ended")

        // Delivering again once the first frame is there.
        isInterrupted = false
        reportState()
    }

    private func handleRuntimeError(_ message: AVCaptureSession.RuntimeErrorMessage) {
        logger.error("Camera runtime error: \(message.description, privacy: .public)")

        fail(.runtimeError(message.description))

        // The session stopped; after a media services reset it can simply run again.
        guard message.isMediaServicesReset, isStarted else { return }

        nonisolated(unsafe) let session = self.session

        sessionQueue.async {
            session.startRunning()
        }
    }

    /// Frames have stopped for a reason the system gave.
    private func fail(_ newFault: CameraFault) {
        receiver.interruptFlow()
        isReceivingFrames = false

        if isStarted, fault == nil {
            fault = newFault
            onReport?(.failed(newFault, lastFrame: receiver.lastFrame().map(MonotonicTimestamp.init(seconds:))))
        }
        reportState()
    }

    private func reportState() {
        let label: String? = if !isStarted {
            nil
        } else if isInterrupted || fault != nil {
            "interrupted"
        } else {
            mode.rawValue
        }

        stateReport.transition(
            to: label,
            format: format,
            frameRate: CameraFrameRatePolicy.frameRate(for: mode, pressure: pressure, precision: precisionFrameRate),
            pressure: pressure,
            droppedFrames: receiver.statistics().dropped
        )
    }
}

/// What the capture and the session queue tell the main actor.
private nonisolated enum CameraNews: Sendable {
    case flow(FrameFlow.Change)
    /// With the generation of the window they belong to.
    case precisionRate(PrecisionRateReport, window: Int)
    case restarted(window: Int)
    case locked(CaptureSettings, window: Int)
}

/// The capture delegate: stamps and counts frames on the capture queue, and
/// keeps the flow and the precision window, which the watchdog looks at on
/// the session queue.
private nonisolated final class FrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    private struct State {
        var statistics = FrameStatistics()
        var handler: (@Sendable (CameraFrame) -> Void)?
        var recorder: (@Sendable (CameraFrame) -> Void)?
        var news: (@Sendable (CameraNews) -> Void)?
        var nextIndex = 0
        var flow = FrameFlow()
        var window: PrecisionWindowMonitor?
        var windowGeneration = 0
    }

    private let state = Mutex(State())

    /// Sample timestamps are on this clock; set once, before frames arrive.
    private let synchronizationClock = Mutex<CMClock?>(nil)

    func setSynchronizationClock(_ clock: CMClock?) {
        synchronizationClock.withLock { $0 = clock }
    }

    func setHandler(_ handler: (@Sendable (CameraFrame) -> Void)?) {
        state.withLock { $0.handler = handler }
    }

    func setRecorder(_ recorder: (@Sendable (CameraFrame) -> Void)?) {
        state.withLock { $0.recorder = recorder }
    }

    func setNewsHandler(_ news: (@Sendable (CameraNews) -> Void)?) {
        state.withLock { $0.news = news }
    }

    /// Exposure, focus and white balance are held for the open window.
    func sendLocked(_ settings: CaptureSettings) {
        let (handler, generation) = state.withLock { ($0.news, $0.windowGeneration) }
        handler?(.locked(settings, window: generation))
    }

    func statistics() -> FrameStatistics {
        state.withLock { $0.statistics }
    }

    /// Returns the statistics up to now and starts counting afresh.
    func resetStatistics() -> FrameStatistics {
        state.withLock {
            let statistics = $0.statistics
            $0.statistics = FrameStatistics()
            return statistics
        }
    }

    func lastFrame() -> TimeInterval? {
        state.withLock { $0.flow.lastFrame }
    }

    func interruptFlow() {
        state.withLock { $0.flow.interrupt() }
    }

    func openWindow(_ window: PrecisionWindowMonitor, generation: Int) {
        state.withLock {
            $0.window = window
            $0.windowGeneration = generation
        }
    }

    func closeWindow() {
        state.withLock { $0.window = nil }
    }

    func windowDelivery() -> PrecisionRateDelivery? {
        state.withLock { $0.window?.deliveryReport }
    }

    /// One look at the flow and the window, on the session queue. Returns
    /// what the window asks for, with the window, if one is open.
    func tick(
        at now: TimeInterval,
        exposure: PrecisionWindowMonitor.Exposure
    ) -> (PrecisionWindowMonitor.Step, PrecisionWindowMonitor)? {
        let (change, step, window, generation, news) = state.withLock { state in
            let change = state.flow.check(at: now)
            let step = state.window?.tick(at: now, exposure: exposure)
            return (change, step, state.window, state.windowGeneration, state.news)
        }

        if let change {
            news?(.flow(change))
        }

        guard let step, let window else { return nil }

        if let report = step.report {
            news?(.precisionRate(report, window: generation))
        }
        return (step, window)
    }

    /// The session runs again since `finished`; frames are expected from then.
    func restarted(began: TimeInterval, finished: TimeInterval) {
        let (news, generation) = state.withLock { state in
            state.window?.restarted(began: began, finished: finished)
            state.flow.expectFrames(from: finished)
            return (state.news, state.windowGeneration)
        }
        news?(.restarted(window: generation))
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let arrived = CACurrentMediaTime()
        let timestamp = hostSeconds(of: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let exposure = Self.exposure(of: sampleBuffer)

        let (handler, recorder, index, change, report, news) = state.withLock { state in
            state.statistics.recordDelivered(at: timestamp, exposure: exposure.duration, iso: exposure.iso)
            state.nextIndex += 1

            let change = state.flow.frameArrived(capturedAt: timestamp, arrivedAt: arrived)
            let step = state.window?.frameArrived(at: timestamp, exposure: exposure.duration, iso: exposure.iso)
            let report = step?.report.map { CameraNews.precisionRate($0, window: state.windowGeneration) }

            return (state.handler, state.recorder, state.nextIndex - 1, change, report, state.news)
        }

        let frame = CameraFrame(
            pixelBuffer: pixelBuffer,
            timestamp: MonotonicTimestamp(seconds: timestamp),
            index: index
        )

        // The analysis first: the recording must not delay a decision.
        handler?(frame)
        recorder?(frame)

        if let change {
            news?(.flow(change))
        }
        if let report {
            news?(report)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let attachment = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
            attachmentModeOut: nil
        ) as? String

        let reason: FrameDropReason = switch attachment {
        case String(kCMSampleBufferDroppedFrameReason_FrameWasLate): .late
        case String(kCMSampleBufferDroppedFrameReason_OutOfBuffers): .outOfBuffers
        case String(kCMSampleBufferDroppedFrameReason_Discontinuity): .discontinuity
        default: .unknown
        }

        state.withLock {
            $0.statistics.recordDropped(reason)
            $0.window?.recordDropped(reason)
        }
    }

    /// The exposure time and ISO the frame was taken with, from its Exif
    /// metadata, if it carries any.
    private static func exposure(of sampleBuffer: CMSampleBuffer) -> (duration: TimeInterval?, iso: Double?) {
        guard let exif = CMGetAttachment(
            sampleBuffer,
            key: kCGImagePropertyExifDictionary,
            attachmentModeOut: nil
        ) as? NSDictionary else {
            return (nil, nil)
        }

        let duration = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue

        return (duration, iso)
    }

    /// The session's clock is the host clock for the built-in camera, but
    /// that is the session's choice, so the conversion is explicit.
    private func hostSeconds(of time: CMTime) -> TimeInterval {
        let clock = synchronizationClock.withLock { $0 }

        guard let clock else { return time.seconds }

        return CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock()).seconds
    }
}

// Typed forms of the notifications the SDK doesn't offer messages for yet.

extension AVCaptureSession {
    nonisolated struct WasInterruptedMessage: NotificationCenter.AsyncMessage {
        typealias Subject = AVCaptureSession

        /// Raw value of `AVCaptureSession.InterruptionReason`.
        let reason: Int?

        static var name: Notification.Name { AVCaptureSession.wasInterruptedNotification }

        static func makeMessage(_ notification: Notification) -> Self? {
            Self(reason: notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
        }
    }

    nonisolated struct InterruptionEndedMessage: NotificationCenter.AsyncMessage {
        typealias Subject = AVCaptureSession

        static var name: Notification.Name { AVCaptureSession.interruptionEndedNotification }

        static func makeMessage(_ notification: Notification) -> Self? { Self() }
    }

    nonisolated struct RuntimeErrorMessage: NotificationCenter.AsyncMessage {
        typealias Subject = AVCaptureSession

        let description: String
        let isMediaServicesReset: Bool

        static var name: Notification.Name { AVCaptureSession.runtimeErrorNotification }

        static func makeMessage(_ notification: Notification) -> Self? {
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError

            return Self(
                description: error?.localizedDescription ?? "unknown",
                isMediaServicesReset: error?.code == .mediaServicesWereReset
            )
        }
    }
}
