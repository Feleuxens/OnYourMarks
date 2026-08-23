//
//  CameraMovementDetector.swift
//  OnYourMarks
//
//  Created by Felix on 17.07.26.
//

import AVFoundation
import Vision
import QuartzCore
import OSLog

@Observable
final class CameraMovementDetector: NSObject, MovementDetector {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OnYourMarks", category: "Camera"
    )
    
    @MainActor var onJoints: (([VNHumanBodyPoseObservation.JointName: CGPoint]) -> Void)?

    var onMovement: ((TimeInterval) -> Void)?
    private var isConfigured = false

    private var device: AVCaptureDevice?
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "camera.frame")
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let poseRequest = VNDetectHumanBodyPoseRequest()

    private(set) var isMonitoring = false
    private var baseline: [VNHumanBodyPoseObservation.JointName: CGPoint]?
    private var baselineFrames = 0
    private var hasTriggered = false

    private let jointsOfInterest: [VNHumanBodyPoseObservation.JointName] =
        [
            .root, .neck,
            .leftHip, .rightHip,
            .leftWrist, .rightWrist,
            .leftElbow, .rightElbow,
            .leftShoulder, .rightShoulder,
            .leftKnee, .rightKnee,
            .leftAnkle, .rightAnkle
        ]
    private let minConfidence: Float = 0.3
    private let baselineFrameCount = 8
    private let movementThreshold: CGFloat = 0.05
    
    func configureIfNeeded() -> Bool {
        if isConfigured { return true }
        
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }
        
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else {
            logger.error("No back camera available")
            return false
        }
        
        
        guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            return false
        }
        
        session.addInput(input)
        
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        
        guard session.canAddOutput(videoOutput) else {
            session.removeInput(input)
            return false
        }
                
        session.addOutput(videoOutput)
        
        device = camera
        isConfigured = true
        return true
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
    
    func startMonitoring() {
        print(
            "Active camera format max FPS:",
            activeFormatMaximumFrameRate() ?? 0
        )
        frameQueue.async { [weak self] in
            guard let self else { return }
            guard let device = self.device else { return }
            
            self.setFrameRate(60, on: device)
            
            self.baseline = nil
            self.baselineFrames = 0
            self.hasTriggered = false
            self.isMonitoring = true
        }
    }
    func stopMonitoring() {
        frameQueue.async { [weak self] in
            guard let self else { return }
            
            // reset variables even if no device exists
            self.isMonitoring = false
            self.baseline = nil
            self.baselineFrames = 0
            self.hasTriggered = false
            
            guard let device = self.device else { return }
            
            self.setFrameRate(15, on: device)
        }
    }
    
    private func setFrameRate(_ requestedFps: Double, on device: AVCaptureDevice) {
        guard requestedFps > 0 else { return }
        
        guard let fps = nearestSupportedFrameRate(to: requestedFps, on: device) else { return }
        
        let frameDuration = CMTime(seconds: 1.0 / fps, preferredTimescale: 60_000)

        do {
            try device.lockForConfiguration()
            
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            
            device.unlockForConfiguration()
        } catch {
            logger.error("Frame-rate config failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func nearestSupportedFrameRate(to requestedFps: Double, on device: AVCaptureDevice) -> Double? {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        
        guard !ranges.isEmpty else { return nil }
        
        // Return exact fps is supported
        if ranges.contains(where: {
            requestedFps >= $0.minFrameRate && requestedFps <= $0.maxFrameRate
        }) {
            return requestedFps
        }
        
        // otherwise choose closest supported boundary
        let supportedBoundaries = ranges.flatMap {
            [$0.minFrameRate, $0.maxFrameRate]
        }
        
        return supportedBoundaries.min {
            abs($0 - requestedFps) < abs($1 - requestedFps)
        }
    }
    
    func activeFormatSupportedFrameRateRanges()
        -> [ClosedRange<Double>]
    {
        guard let device else {
            return []
        }

        return device.activeFormat
            .videoSupportedFrameRateRanges
            .map {
                $0.minFrameRate...$0.maxFrameRate
            }
    }

    func activeFormatMaximumFrameRate() -> Double? {
        activeFormatSupportedFrameRateRanges()
            .map(\.upperBound)
            .max()
    }
}

extension CameraMovementDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let frameTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        guard (try? handler.perform([poseRequest])) != nil,
              let observation = poseRequest.results?.first,
              let points = try? observation.recognizedPoints(.all) else {
            return
        }

        var current: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
        for joint in jointsOfInterest {
            if let p = points[joint], p.confidence >= minConfidence {
                current[joint] = p.location
            }
        }

        let snapshot = current
        DispatchQueue.main.async { [weak self] in
            self?.onJoints?(snapshot)
        }
        
        guard isMonitoring, !hasTriggered, !current.isEmpty else {
            return
        }
        
        if baselineFrames < baselineFrameCount {
            mergeBaseline(current)
            baselineFrames += 1
            return
        }
        guard let baseline else { return }

        var maxDisp: CGFloat = 0
        for (joint, pos) in current {
            if let base = baseline[joint] {
                maxDisp = max(maxDisp, hypot(pos.x - base.x, pos.y - base.y))
            }
        }

        if maxDisp > movementThreshold {
            hasTriggered = true
            let callback = onMovement
            DispatchQueue.main.async { callback?(frameTime) }
        }
    }

    private func mergeBaseline(_ current: [VNHumanBodyPoseObservation.JointName: CGPoint]) {
        guard baseline != nil else { baseline = current; return }
        for (joint, pos) in current {
            if let existing = baseline?[joint] {
                baseline?[joint] = CGPoint(x: (existing.x + pos.x) / 2, y: (existing.y + pos.y) / 2)
            } else {
                baseline?[joint] = pos
            }
        }
    }
}
