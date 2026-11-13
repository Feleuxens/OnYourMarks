//
//  CameraMotionTests.swift
//  OnYourMarksTests
//

import CoreVideo
import Foundation
import Testing
@testable import OnYourMarks

struct CameraMotionTests {
    /// A picture of irregular patches, with its content moved by the given
    /// pixels to the right and downwards.
    private func picture(width: Int = 640, height: Int = 360, movedRight dx: Int = 0, down dy: Int = 0) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &created)
        let buffer = try #require(created)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        for y in 0..<height {
            for x in 0..<width {
                let sourceX = x - dx, sourceY = y - dy
                // Patches of 24 px with a brightness that depends on their place.
                let patch = (sourceX.quotientAndRemainder(dividingBy: 24).quotient &* 73_856_093)
                    ^ (sourceY.quotientAndRemainder(dividingBy: 24).quotient &* 19_349_663)
                let value = UInt8(truncatingIfNeeded: (patch &* 2_654_435_761) >> 8)

                let pixel = base + y * bytesPerRow + x * 4
                pixel[0] = value
                pixel[1] = value
                pixel[2] = value
                pixel[3] = 255
            }
        }
        return buffer
    }

    @Test(arguments: [(640, 360, 12, -7), (1280, 720, -20, 15), (640, 360, 0, 0)])
    func measuresHowFarTheContentMoved(width: Int, height: Int, right: Int, down: Int) throws {
        let shift = try #require(
            CameraMotionEstimator.contentShift(
                from: try picture(width: width, height: height),
                to: try picture(width: width, height: height, movedRight: right, down: down)
            )
        )

        #expect(abs(shift.dx - CGFloat(right)) < 1)
        #expect(abs(shift.dy - CGFloat(down)) < 1)
    }

    /// The buffer lies on its side: its right is the upright picture's
    /// bottom, its bottom the picture's left.
    @Test
    func bufferShiftsBecomeShiftsOfTheUprightPicture() {
        let right = CameraMotionEstimator.pictureOffset(ofBufferShift: CGVector(dx: 192, dy: 0), bufferWidth: 1920, bufferHeight: 1080)
        #expect(abs(right.x) < 0.000_001)
        #expect(abs(right.y + 0.1) < 0.000_001)

        let down = CameraMotionEstimator.pictureOffset(ofBufferShift: CGVector(dx: 0, dy: 108), bufferWidth: 1920, bufferHeight: 1080)
        #expect(abs(down.x + 0.1) < 0.000_001)
        #expect(abs(down.y) < 0.000_001)
    }

    private func frame(_ buffer: CVPixelBuffer, at seconds: TimeInterval) -> CameraFrame {
        CameraFrame(pixelBuffer: buffer, timestamp: MonotonicTimestamp(seconds: seconds), index: 0)
    }

    @Test
    func offsetsAreMeasuredAgainstTheFirstFrameAfterAReset() throws {
        let estimator = CameraMotionEstimator()

        #expect(estimator.shift(in: frame(try picture(), at: 0)) == .measured(.zero))

        // Not accumulated: each frame is compared with the reference itself.
        _ = estimator.shift(in: frame(try picture(movedRight: 12), at: 0.01))
        let offset = try #require(estimator.shift(in: frame(try picture(movedRight: 16, down: 9), at: 0.02)).offset)
        #expect(abs(offset.x + 9.0 / 360) < 0.003)
        #expect(abs(offset.y + 16.0 / 640) < 0.003)

        estimator.reset()
        #expect(estimator.shift(in: frame(try picture(movedRight: 16, down: 9), at: 0.03)) == .measured(.zero))
    }

    @Test
    func theReferenceIsACopyWithTheSamePixels() throws {
        let original = try picture(movedRight: 5)
        let copy = try #require(CameraMotionEstimator.copy(of: original))

        #expect(copy !== original)

        let shift = try #require(CameraMotionEstimator.contentShift(from: copy, to: try picture(movedRight: 17)))
        #expect(abs(shift.dx - 12) < 1)
        #expect(abs(shift.dy) < 1)
    }

    @Test
    func aShiftTooLargeToBeTremorIsNotMeasured() throws {
        let estimator = CameraMotionEstimator()

        _ = estimator.shift(in: frame(try picture(), at: 0))
        #expect(estimator.shift(in: frame(try picture(movedRight: 16), at: 0.01)).offset != nil)

        // Half the picture's width away: nothing to correct by, and the
        // shift before it says nothing about this frame.
        #expect(estimator.shift(in: frame(try picture(movedRight: 320), at: 0.02)) == .unmeasured)

        // One such frame is passed over; the reference is still the first picture.
        let offset = try #require(estimator.shift(in: frame(try picture(movedRight: 16), at: 0.03)).offset)
        #expect(abs(offset.y + 16.0 / 640) < 0.003)
    }

    @Test
    func aCameraThatStaysAwayIsMeasuredAgainstANewPicture() throws {
        let estimator = CameraMotionEstimator()
        let patience = CameraMotionEstimator.patience

        _ = estimator.shift(in: frame(try picture(), at: 0))

        // A pan that ends half the picture's width away.
        #expect(estimator.shift(in: frame(try picture(movedRight: 320), at: 1)) == .unmeasured)
        #expect(estimator.shift(in: frame(try picture(movedRight: 320), at: 1 + patience / 2)) == .unmeasured)
        #expect(estimator.shift(in: frame(try picture(movedRight: 320), at: 1 + patience + 0.01)) == .lost)

        // The picture after that is the one to measure against.
        #expect(estimator.shift(in: frame(try picture(movedRight: 320), at: 1.2)) == .measured(.zero))
        let offset = try #require(estimator.shift(in: frame(try picture(movedRight: 336), at: 1.21)).offset)
        #expect(abs(offset.y + 16.0 / 640) < 0.003)
    }
}
