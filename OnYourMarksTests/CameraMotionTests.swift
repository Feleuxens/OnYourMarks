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

    @Test
    func offsetsAreMeasuredAgainstTheFirstFrameAfterAReset() throws {
        let estimator = CameraMotionEstimator()
        func frame(_ buffer: CVPixelBuffer, _ index: Int) -> CameraFrame {
            CameraFrame(pixelBuffer: buffer, timestamp: MonotonicTimestamp(seconds: Double(index)), index: index)
        }

        #expect(estimator.offset(in: frame(try picture(), 0)) == .zero)

        // Not accumulated: each frame is compared with the reference itself.
        _ = estimator.offset(in: frame(try picture(movedRight: 30), 1))
        let offset = estimator.offset(in: frame(try picture(movedRight: 16, down: 9), 2))
        #expect(abs(offset.x + 9.0 / 360) < 0.003)
        #expect(abs(offset.y + 16.0 / 640) < 0.003)

        estimator.reset()
        #expect(estimator.offset(in: frame(try picture(movedRight: 16, down: 9), 3)) == .zero)
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
    func aShiftTooLargeToBeTremorIsNotApplied() throws {
        let estimator = CameraMotionEstimator()
        func frame(_ buffer: CVPixelBuffer, _ index: Int) -> CameraFrame {
            CameraFrame(pixelBuffer: buffer, timestamp: MonotonicTimestamp(seconds: Double(index)), index: index)
        }

        _ = estimator.offset(in: frame(try picture(), 0))
        let small = estimator.offset(in: frame(try picture(movedRight: 16), 1))

        // Half the picture's width away: the last trusted shift stays.
        #expect(estimator.offset(in: frame(try picture(movedRight: 320), 2)) == small)
    }
}
