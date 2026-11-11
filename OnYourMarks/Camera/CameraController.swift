//
//  CameraController.swift
//  OnYourMarks
//

import AVFoundation
import OSLog
import Synchronization

/// Owns the capture session: picks the format, switches between the idle and
/// the precision frame rate, watches system pressure and hands every frame,
/// with its capture time, to whoever analyses it.
@Observable
final class CameraController {
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

    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var device: AVCaptureDevice?

    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let receiver = FrameReceiver()
    @ObservationIgnored private let frameQueue = DispatchSerialQueue(label: "camera.frame")
    @ObservationIgnored private let sessionQueue = DispatchSerialQueue(label: "camera.session")

    @ObservationIgnored private let stateReport = CameraStateReport()
    @ObservationIgnored private var pressureObservation: NSKeyValueObservation?
    @ObservationIgnored private var observerTokens: [NotificationCenter.ObservationToken] = []

    isolated deinit {
        pressureObservation?.invalidate()

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
        selectFormat(on: camera)

        receiver.setSynchronizationClock(session.synchronizationClock)
        device = camera
        isConfigured = true

        observePressure(of: camera)
        observeSession()
        return true
    }

    private func selectFormat(on camera: AVCaptureDevice) {
        let formats = camera.formats
        let descriptors = formats.map(CameraFormatDescriptor.init)

        guard let index = CameraFormatSelector.bestIndex(among: descriptors, frameRate: precisionFrameRate) else {
            logger.error("The camera offers no formats")
            return
        }

        let chosen = descriptors[index]

        do {
            try camera.lockForConfiguration()
            camera.activeFormat = formats[index]
            Self.setFrameRate(CameraFrameRatePolicy.idle, on: camera)
            camera.unlockForConfiguration()
        } catch {
            logger.error("Could not select the camera format: \(error.localizedDescription, privacy: .public)")
            format = CameraFormatDescriptor(camera.activeFormat)
            return
        }

        format = chosen

        logger.info(
            """
            Camera format \(chosen.width)x\(chosen.height), up to \
            \(chosen.maxFrameRate, format: .fixed(precision: 0)) fps, \
            auto low-light frame rate \(chosen.supportsAutoFrameRate ? "supported" : "unsupported", privacy: .public) \
            (of \(formats.count) formats)
            """
        )

        if chosen.maxFrameRate < precisionFrameRate {
            logger.notice("No format reaches \(self.precisionFrameRate, format: .fixed(precision: 0)) fps")
        }
    }

    /// Changes the precision rate. A configured camera picks its format
    /// anew, which interrupts a running stream for a moment, so this is for
    /// settings, not for a start in progress.
    func setPrecisionFrameRate(_ frameRate: Double) {
        guard frameRate != precisionFrameRate else { return }

        precisionFrameRate = frameRate

        guard isConfigured, let device else { return }

        session.beginConfiguration()
        selectFormat(on: device)
        session.commitConfiguration()

        applyFrameRate()
        reportState()
    }

    // MARK: - Running

    func start() {
        guard isConfigured, !isStarted else { return }
        isStarted = true

        // AVCaptureSession isn't Sendable; it only starts and stops on the
        // serial session queue, after its configuration on the main actor.
        nonisolated(unsafe) let session = self.session

        sessionQueue.async {
            guard !session.isRunning else { return }
            session.startRunning()
        }

        reportState()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

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

    /// Frames since the mode last changed.
    func currentStatistics() -> FrameStatistics {
        receiver.statistics()
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
        applyFrameRate()
        reportState()
    }

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

    /// Fixes the rate by setting both bounds. The device must be locked.
    ///
    /// The automatic low-light frame rate stays off: it would take the rate
    /// out of our hands, and setting a duration while it is on raises an exception.
    private nonisolated static func setFrameRate(_ requested: Double, on device: AVCaptureDevice) {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate }

        guard let frameRate = CameraFrameRatePolicy.supported(requested, in: ranges) else { return }

        let frameDuration = CMTime(seconds: 1 / frameRate, preferredTimescale: 60_000)

        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
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
        reportState()
    }

    private func handleInterruptionEnded() {
        logger.notice("Camera interruption ended")

        isInterrupted = false
        reportState()
    }

    private func handleRuntimeError(_ message: AVCaptureSession.RuntimeErrorMessage) {
        logger.error("Camera runtime error: \(message.description, privacy: .public)")

        // The session stopped; after a media services reset it can simply run again.
        guard message.isMediaServicesReset, isStarted else { return }

        nonisolated(unsafe) let session = self.session

        sessionQueue.async {
            session.startRunning()
        }
    }

    private func reportState() {
        let label: String? = if !isStarted {
            nil
        } else if isInterrupted {
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

/// The capture delegate: stamps and counts frames on the capture queue.
private nonisolated final class FrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    private struct State {
        var statistics = FrameStatistics()
        var handler: (@Sendable (CameraFrame) -> Void)?
        var nextIndex = 0
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

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let timestamp = hostSeconds(of: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        let (handler, index) = state.withLock { state in
            state.statistics.recordDelivered(at: timestamp)
            state.nextIndex += 1
            return (state.handler, state.nextIndex - 1)
        }

        handler?(
            CameraFrame(
                pixelBuffer: pixelBuffer,
                timestamp: MonotonicTimestamp(seconds: timestamp),
                index: index
            )
        )
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

        state.withLock { $0.statistics.recordDropped(reason) }
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
