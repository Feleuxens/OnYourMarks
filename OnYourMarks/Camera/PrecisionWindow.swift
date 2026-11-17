//
//  PrecisionWindow.swift
//  OnYourMarks
//

import CoreMedia
import Foundation

/// Whether frames are arriving, judged by when the last one did.
nonisolated struct FrameFlow: Equatable, Sendable {
    /// Longer than this without a frame and the camera has stopped: two and
    /// a half frame intervals at the slowest rate it runs at (5 fps under
    /// pressure, `CameraFrameRatePolicy.throttledIdle`), and twice the
    /// longest switch from idle to precision measured on the device (251 ms).
    static let stallTimeout: TimeInterval = 0.5

    nonisolated enum Change: Equatable, Sendable {
        case began
        /// With the capture time of the last frame that arrived.
        case stopped(lastFrame: TimeInterval?)
    }

    private(set) var isDelivering = false

    /// Capture time of the newest frame.
    private(set) var lastFrame: TimeInterval?

    /// Host time the newest frame arrived, or from when one is expected.
    /// Arrival, not capture: the time from capture to delivery is no pause.
    private var lastSign: TimeInterval?

    /// - Parameters:
    ///   - capturedAt: the frame's capture time.
    ///   - arrivedAt: the host time it was delivered.
    mutating func frameArrived(capturedAt: TimeInterval, arrivedAt: TimeInterval) -> Change? {
        lastFrame = capturedAt
        lastSign = arrivedAt

        guard !isDelivering else { return nil }

        isDelivering = true
        return .began
    }

    /// Looked at regularly while the camera runs.
    mutating func check(at now: TimeInterval) -> Change? {
        guard isDelivering, let lastSign, now - lastSign > Self.stallTimeout else { return nil }

        isDelivering = false
        return .stopped(lastFrame: lastFrame)
    }

    /// Frames stop for a reason that is known (an interruption, an error,
    /// switching off). The next frame begins the flow anew.
    mutating func interrupt() {
        isDelivering = false
    }

    /// No frame since `time` is no pause: the session was just started again.
    mutating func expectFrames(from time: TimeInterval) {
        lastSign = max(lastSign ?? time, time)
    }
}

/// Watches one precision window: whether the rate arrives, restarts the
/// session once if it does not, and holds exposure, focus and white balance
/// once the picture has settled at the new rate.
///
/// The device takes the precision frame durations every time, but a running
/// session has been measured to go on at the rate it had (CLAUDE.md, open
/// work); a session started at the precision rate delivered it.
nonisolated struct PrecisionWindowMonitor: Sendable {
    /// How long the rate gets to arrive before the session is restarted:
    /// the longest switch measured on the device (251 ms, median 142 ms, in
    /// 12 windows that all arrived), the frames that show the rate
    /// (`arrivalRun` intervals, 50 ms at 60 fps), and one idle frame interval
    /// (67 ms) of margin, rounded up.
    static let arrivalDeadline: TimeInterval = 0.4

    /// One restart per window. Whether a restart cures a rate that did not
    /// arrive is unmeasured; a second one would only hold the field longer.
    static let maximumRestarts = 1

    /// The rate has arrived with this many intervals in a row at it. One
    /// short interval can be jitter after a late frame; three in a row are
    /// the rate.
    static let arrivalRun = 3

    /// An interval of up to this many frame durations is at the rate, as in
    /// `thePrecisionRateArrivesEveryTime`. Far below the idle interval
    /// (67 ms) and the 30 fps the device has fallen back to (33 ms).
    static let arrivalTolerance = 1.5

    /// Auto exposure reports adjusting only a few frames after the frame
    /// duration changed; judged sooner, a picture about to adjust looks
    /// settled. Reasoned: a dozen frames at 120 fps.
    static let minimumSettle: TimeInterval = 0.1

    /// After this the settings are locked as they are, still adjusting or
    /// not: then at least nothing moves during the hold. Reasoned, not
    /// measured; `exposureIsHeldThroughThePrecisionWindow` reports how long
    /// settling takes.
    static let settleTimeout: TimeInterval = 0.5

    /// Exposure times are given in whole nanoseconds or coarser.
    static let exposureTolerance: TimeInterval = 1e-6

    nonisolated enum Phase: Equatable, Sendable {
        /// Waiting for the rate.
        case switching
        /// The session is being started again.
        case restarting
        /// The rate is decided; exposure, focus and white balance are settling.
        case settling
        /// Settings held: ready for the gun.
        case steady
    }

    nonisolated enum Action: Equatable, Sendable {
        case restart
        case lock(hasSettled: Bool)
    }

    /// What one frame or one look at the time leads to.
    nonisolated struct Step: Equatable, Sendable {
        var action: Action?
        var report: PrecisionRateReport?

        static let none = Step()
    }

    /// What the camera's exposure is doing, as the device says.
    nonisolated struct Exposure: Equatable, Sendable {
        /// Exposure, focus or white balance.
        let isAdjusting: Bool
        let duration: TimeInterval
    }

    let requestedFrameRate: Double
    let expectedFrameRate: Double
    let openedAt: TimeInterval

    /// What auto exposure may use at most in this window.
    let maximumExposure: TimeInterval?

    private(set) var phase = Phase.switching
    private(set) var restarts = 0
    private(set) var restartedAt: TimeInterval?
    private(set) var arrivedAt: TimeInterval?

    /// The frames from when the rate was decided on.
    private(set) var delivery = FrameStatistics()

    /// Frames from before this are from before the rate was asked for, or
    /// from before the restart.
    private var switchBegan: TimeInterval
    /// The deadline counts from here: the opening, or the end of the restart.
    private var waitingSince: TimeInterval
    private var settlingSince: TimeInterval?

    /// Capture times of the latest frames that followed each other at the rate.
    private var run: [TimeInterval] = []

    init(requested: Double, expected: Double, openedAt: TimeInterval, maximumExposure: TimeInterval? = nil) {
        requestedFrameRate = requested
        expectedFrameRate = expected
        self.openedAt = openedAt
        self.maximumExposure = maximumExposure
        switchBegan = openedAt
        waitingSince = openedAt
    }

    mutating func frameArrived(
        at time: TimeInterval,
        exposure: TimeInterval? = nil,
        iso: Double? = nil
    ) -> Step {
        switch phase {
        case .restarting:
            // From the session that is being stopped.
            return .none

        case .settling, .steady:
            delivery.recordDelivered(at: time, exposure: exposure, iso: iso)
            return .none

        case .switching:
            guard time >= switchBegan else { return .none }

            if let last = run.last, time - last <= Self.arrivalTolerance / expectedFrameRate {
                run.append(time)
            } else {
                run = [time]
            }

            guard run.count > Self.arrivalRun, let first = run.first else { return .none }

            arrivedAt = first
            for frame in run.dropLast() {
                delivery.recordDelivered(at: frame)
            }
            delivery.recordDelivered(at: time, exposure: exposure, iso: iso)
            beginSettling(at: time)

            return Step(report: report(restarts == 0 ? .arrived : .arrivedAfterRestart))
        }
    }

    /// Looked at regularly while the window is open.
    mutating func tick(at now: TimeInterval, exposure: Exposure) -> Step {
        switch phase {
        case .switching:
            guard now - waitingSince > Self.arrivalDeadline else { return .none }

            guard restarts < Self.maximumRestarts else {
                beginSettling(at: now)
                return Step(report: report(.missed))
            }

            restarts += 1
            phase = .restarting
            return Step(action: .restart)

        case .restarting, .steady:
            return .none

        case .settling:
            let since = settlingSince ?? now
            let isCapped = maximumExposure.map { exposure.duration <= $0 + Self.exposureTolerance } ?? true
            let hasSettled = !exposure.isAdjusting && isCapped

            if hasSettled, now - since >= Self.minimumSettle {
                phase = .steady
                return Step(action: .lock(hasSettled: true))
            }

            guard now - since > Self.settleTimeout else { return .none }

            phase = .steady
            return Step(action: .lock(hasSettled: false))
        }
    }

    /// The session was stopped at `began` and runs again since `finished`.
    mutating func restarted(began: TimeInterval, finished: TimeInterval) {
        guard phase == .restarting else { return }

        restartedAt = finished
        switchBegan = began
        waitingSince = finished
        run = []
        phase = .switching
    }

    private mutating func beginSettling(at time: TimeInterval) {
        phase = .settling
        settlingSince = time
        run = []
    }

    private func report(_ outcome: PrecisionRateReport.Outcome) -> PrecisionRateReport {
        PrecisionRateReport(
            requestedFrameRate: requestedFrameRate,
            expectedFrameRate: expectedFrameRate,
            outcome: outcome,
            requestedAt: MonotonicTimestamp(seconds: openedAt),
            restartedAt: restartedAt.map(MonotonicTimestamp.init(seconds:)),
            arrivedAt: outcome == .missed ? nil : arrivedAt.map(MonotonicTimestamp.init(seconds:))
        )
    }

    /// What the window has delivered so far.
    var deliveryReport: PrecisionRateDelivery {
        PrecisionRateDelivery(
            requestedFrameRate: requestedFrameRate,
            deliveredFrameRate: delivery.deliveredFrameRate,
            frames: delivery.delivered,
            dropped: delivery.dropped,
            longestGap: delivery.longestGap,
            exposureDurations: delivery.exposureDurations,
            isoValues: delivery.isoValues
        )
    }

    mutating func recordDropped(_ reason: FrameDropReason) {
        guard phase == .settling || phase == .steady else { return }
        delivery.recordDropped(reason)
    }
}

/// What may be set on the camera's exposure, focus and white balance.
/// Setting a mode or a value the device does not support raises an
/// exception that cannot be caught, so every value goes through here.
nonisolated enum CaptureSettingsPolicy {
    /// The longest exposure in precision mode, as a share of the frame
    /// duration: a movement smears over at most half the time between two
    /// frames, so the frame in which it first shows was exposed within half
    /// a frame of it (4.2 ms at 120 fps, 2.1 ms at 240 fps). Shorter costs
    /// ISO, and with it noise, which the 40×40 grid of the onset analysis
    /// averages out only so far. Reasoned, not measured.
    static let maximumExposureShare = 0.5

    nonisolated enum Adjustment: Hashable, Sendable {
        case locked
        case continuous
    }

    /// The modes the device supports.
    nonisolated struct Support: Equatable, Sendable {
        var exposure: Set<Adjustment> = []
        var focus: Set<Adjustment> = []
        var whiteBalance: Set<Adjustment> = []
    }

    /// The modes to set; nil leaves one as it is.
    nonisolated struct Modes: Equatable, Sendable {
        var exposure: Adjustment?
        var focus: Adjustment?
        var whiteBalance: Adjustment?
    }

    /// Exposure times are handed to the device in nanoseconds, rounded down:
    /// rounded up, the cap could lie above the format's longest exposure.
    static let exposureTimescale: CMTimeScale = 1_000_000_000

    /// The longest exposure auto exposure may use at the given rate, within
    /// the format's own bounds (anything outside raises). Nil without a rate
    /// or with bounds that are no times.
    static func maximumExposure(frameRate: Double, supported: ClosedRange<CMTime>) -> CMTime? {
        guard frameRate > 0,
              supported.lowerBound.isNumeric, supported.upperBound.isNumeric,
              supported.lowerBound > .zero else {
            return nil
        }

        let nanoseconds = (maximumExposureShare / frameRate * Double(exposureTimescale)).rounded(.down)
        let wanted = CMTime(value: CMTimeValue(nanoseconds), timescale: exposureTimescale)

        return wanted.clamped(to: supported)
    }

    /// Each of the three set to `adjustment` where the device supports it.
    static func modes(_ adjustment: Adjustment, supported: Support) -> Modes {
        Modes(
            exposure: supported.exposure.contains(adjustment) ? adjustment : nil,
            focus: supported.focus.contains(adjustment) ? adjustment : nil,
            whiteBalance: supported.whiteBalance.contains(adjustment) ? adjustment : nil
        )
    }
}
