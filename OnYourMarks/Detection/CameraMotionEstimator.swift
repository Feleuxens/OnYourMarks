//
//  CameraMotionEstimator.swift
//  OnYourMarks
//

import CoreVideo
import Vision

/// Measures how far the whole picture has shifted since a reference frame,
/// which is what a camera held in the hand does to it.
///
/// A first, simple compensation: translation only, no rotation or zoom, and
/// athletes filling much of the picture pull the estimate towards themselves.
///
/// Not thread-safe: use it from one queue only, here the pose queue.
nonisolated final class CameraMotionEstimator: @unchecked Sendable {
    /// A shift beyond this share of the picture is not a hand's tremor but
    /// a pan or a failed measurement; either way nothing to correct by.
    static let maximumOffset: CGFloat = 0.2

    /// A copy: holding on to one of the camera's own buffers stalls the
    /// capture (measured: 18 frames in 3 s instead of about 240).
    private var reference: CVPixelBuffer?
    private var lastOffset = CGPoint.zero

    /// The next frame becomes the reference.
    func reset() {
        reference = nil
        lastOffset = .zero
    }

    /// How far the content of the frame has shifted against the reference,
    /// in the normalized upright picture the poses use. Zero for the
    /// reference itself; the last known shift if this one can't be measured.
    func offset(in frame: CameraFrame) -> CGPoint {
        guard let reference else {
            self.reference = Self.copy(of: frame.pixelBuffer)
            return .zero
        }

        guard let shift = Self.contentShift(from: reference, to: frame.pixelBuffer) else {
            return lastOffset
        }

        let offset = Self.pictureOffset(
            ofBufferShift: shift,
            bufferWidth: CVPixelBufferGetWidth(frame.pixelBuffer),
            bufferHeight: CVPixelBufferGetHeight(frame.pixelBuffer)
        )

        if hypot(offset.x, offset.y) <= Self.maximumOffset {
            lastOffset = offset
        }
        return lastOffset
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
