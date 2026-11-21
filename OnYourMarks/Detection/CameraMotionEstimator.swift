//
//  CameraMotionEstimator.swift
//  OnYourMarks
//

import CoreVideo
import Synchronization
import Vision

/// What the camera's own movement did to a frame.
nonisolated enum CameraShift: Equatable, Sendable {
    /// How far the picture's content has shifted since the reference, in
    /// the normalized upright picture the poses use.
    case measured(CGPoint)

    /// Not measurable in this frame. Nobody can be judged in it: an older
    /// shift is no substitute, with it whatever the camera did since
    /// would be taken for the athletes' movement.
    case unmeasured

    /// Not measurable for too long. The reference is given up and the
    /// next frame becomes the new one; positions from before can't be
    /// compared with those after, so everyone has to become still again.
    case lost

    var offset: CGPoint? {
        if case .measured(let offset) = self { offset } else { nil }
    }
}

/// Measures how far the whole picture has shifted since a reference frame,
/// which is what a camera held in the hand does to it.
///
/// A first, simple compensation: translation only, no rotation or zoom, and
/// athletes filling much of the picture pull the estimate towards themselves.
nonisolated final class CameraMotionEstimator: Sendable {
    /// A shift beyond this share of the picture is not a hand's tremor but
    /// a pan or a failed measurement; either way nothing to correct by.
    /// Reasoned, not measured.
    static let maximumOffset: CGFloat = 0.2

    private struct State {
        /// A copy: holding on to one of the camera's own buffers stalls the
        /// capture (measured: 18 frames in 3 s instead of about 240).
        var reference: CVPixelBuffer?
        var unmeasuredSince: MonotonicTimestamp?
    }

    /// Only ever used by one queue, the pose queue, so the lock is never
    /// contended; it makes that a guarantee instead of a promise.
    private let state = Mutex(State())

    /// How long the shift may stay unmeasurable before the reference is
    /// given up: as long as the tracker waits before it calls an athlete
    /// hidden. One frame the registration got wrong is passed over; a pan
    /// stays out of reach of the old reference for good.
    static let patience: TimeInterval = AthleteTracker.occlusionDelay

    /// The next frame becomes the reference.
    func reset() {
        state.withLock { $0 = State() }
    }

    /// The shift of the frame's content against the reference; zero for
    /// the reference itself.
    func shift(in frame: CameraFrame) -> CameraShift {
        state.withLock { state in
            guard let reference = state.reference else {
                frame.withPixelBuffer { state.reference = Self.copy(of: $0) }
                state.unmeasuredSince = nil
                return .measured(.zero)
            }

            if let offset = frame.withPixelBuffer({ Self.offset(from: reference, to: $0) }) {
                state.unmeasuredSince = nil
                return .measured(offset)
            }

            guard let unmeasuredSince = state.unmeasuredSince else {
                state.unmeasuredSince = frame.timestamp
                return .unmeasured
            }

            guard frame.timestamp.seconds - unmeasuredSince.seconds > Self.patience else { return .unmeasured }

            state = State()
            return .lost
        }
    }

    /// Nil if the registration fails or finds a shift too large to correct by.
    private static func offset(from reference: CVPixelBuffer, to current: CVPixelBuffer) -> CGPoint? {
        guard let shift = contentShift(from: reference, to: current) else { return nil }

        let offset = pictureOffset(
            ofBufferShift: shift,
            bufferWidth: CVPixelBufferGetWidth(current),
            bufferHeight: CVPixelBufferGetHeight(current)
        )

        return hypot(offset.x, offset.y) <= maximumOffset ? offset : nil
    }

    /// A buffer of our own with the same pixels.
    static func copy(of source: CVPixelBuffer) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(
            nil,
            CVPixelBufferGetWidth(source),
            CVPixelBufferGetHeight(source),
            CVPixelBufferGetPixelFormatType(source),
            nil,
            &created
        )

        guard let copy = created else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        func copyRows(from: UnsafeMutableRawPointer?, to: UnsafeMutableRawPointer?, rows: Int, fromStride: Int, toStride: Int) {
            guard let from, let to else { return }

            for row in 0..<rows {
                memcpy(to + row * toStride, from + row * fromStride, min(fromStride, toStride))
            }
        }

        let planes = CVPixelBufferGetPlaneCount(source)

        if planes == 0 {
            copyRows(
                from: CVPixelBufferGetBaseAddress(source),
                to: CVPixelBufferGetBaseAddress(copy),
                rows: CVPixelBufferGetHeight(source),
                fromStride: CVPixelBufferGetBytesPerRow(source),
                toStride: CVPixelBufferGetBytesPerRow(copy)
            )
        } else {
            for plane in 0..<planes {
                copyRows(
                    from: CVPixelBufferGetBaseAddressOfPlane(source, plane),
                    to: CVPixelBufferGetBaseAddressOfPlane(copy, plane),
                    rows: CVPixelBufferGetHeightOfPlane(source, plane),
                    fromStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                    toStride: CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
                )
            }
        }
        return copy
    }

    /// How many pixels the content moved from one buffer to the next, to
    /// the right and downwards in the buffer.
    static func contentShift(from reference: CVPixelBuffer, to current: CVPixelBuffer) -> CGVector? {
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: current, options: [:])
        let handler = VNImageRequestHandler(cvPixelBuffer: reference, options: [:])

        guard (try? handler.perform([request])) != nil,
              let transform = request.results?.first?.alignmentTransform else {
            return nil
        }

        // The transform moves the current picture back onto the reference,
        // in Vision's coordinates with y pointing up; hence the signs.
        return CGVector(dx: -transform.tx, dy: transform.ty)
    }

    /// Turns a shift in the buffer, which lies on its side, into one in the
    /// upright picture: the buffer's right is the picture's bottom and the
    /// buffer's bottom the picture's left, both with the origin at the top
    /// left; the picture's coordinates start at the bottom left.
    static func pictureOffset(ofBufferShift shift: CGVector, bufferWidth: Int, bufferHeight: Int) -> CGPoint {
        CGPoint(
            x: -shift.dy / CGFloat(max(bufferHeight, 1)),
            y: -shift.dx / CGFloat(max(bufferWidth, 1))
        )
    }
}
