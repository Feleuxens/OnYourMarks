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
import Synchronization

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
    /// Only used from frameQueue, which is serial, so it is never shared between threads.
    private nonisolated(unsafe) let poseRequest = VNDetectHumanBodyPoseRequest()
    private let sessionQueue = DispatchQueue(label: "camera.session")

    private(set) var isMonitoring = false
    private nonisolated let motionState = Mutex(MotionState())
    
    private nonisolated static let jointsOfInterest: [VNHumanBodyPoseObservation.JointName] =
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
        // AVCaptureSession isn't sendable for run on serial sessionQueue
        // Configuration is on main actor and completes before the first start is dispatched
        nonisolated(unsafe) let session = self.session
        
        sessionQueue.async {
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stopSession() {
        nonisolated(unsafe) let session = self.session
        
        sessionQueue.async {
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }
    
    func startMonitoring() {
        print(
            "Active camera format max FPS:",
            activeFormatMaximumFrameRate() ?? 0
        )
        
        motionState.withLock { $0.reset(monitoring: true) }
        isMonitoring = true
        
        setFrameRate(60)
    }
    
    func stopMonitoring() {
        motionState.withLock { $0.reset(monitoring: false) }
        isMonitoring = false
        
        setFrameRate(15)
    }
    
    private func setFrameRate(_ requestedFps: Double) {
        guard requestedFps > 0, let device else { return }
        
        // since AVCaptureDevice isn't Sendable, it is only reconfigured
        // on the serial sessionQueue
        nonisolated(unsafe) let captureDevice = device
        let logger = self.logger
        
        sessionQueue.async {
            CameraMovementDetector.applyFrameRate(requestedFps, to: captureDevice, logger: logger)
        }
    }
    
    private nonisolated static func applyFrameRate(
        _ requestFps: Double,
        to device: AVCaptureDevice,
        logger: Logger
    ) {
        guard let fps = nearestSupportedFrameRate(to: requestFps, on: device) else { return }
        
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
    
    private nonisolated static func nearestSupportedFrameRate(to requestedFps: Double, on device: AVCaptureDevice) -> Double? {
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

extension CameraMovementDetector: nonisolated AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
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
        for joint in Self.jointsOfInterest {
            if let p = points[joint], p.confidence >= minConfidence {
                current[joint] = p.location
            }
        }
        
        let joints = current
        DispatchQueue.main.async { [weak self] in
            self?.onJoints?(joints)
        }
        
        let movementDetected = motionState.withLock { state in
            state.process(joints)
        }
        
        guard movementDetected else { return }
        
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.onMovement?(frameTime)
            }
        }
    }
}

nonisolated struct MotionState {
    static let baselineFrameCount = 8
    static let movementThreshold: CGFloat = 0.05
    
    private var isMonitoring = false
    private var hasTriggered = false
    private var baseline: [VNHumanBodyPoseObservation.JointName: CGPoint]?
    private var baselineFrames = 0
    
    mutating func reset(monitoring: Bool) {
        isMonitoring = monitoring
        hasTriggered = false
        baseline = nil
        baselineFrames = 0
    }
    
    mutating func process(
        _ joints: [VNHumanBodyPoseObservation.JointName: CGPoint]
    ) -> Bool {
        guard isMonitoring, !hasTriggered, !joints.isEmpty else {
            return false
        }
        
        if baselineFrames < Self.baselineFrameCount {
            mergeBaseline(joints)
            baselineFrames += 1
            return false
        }
        
        guard let baseline else { return false }
        
        var maxDisplacement: CGFloat = 0
        for (joint, position) in joints {
            if let base = baseline[joint] {
                maxDisplacement = max(maxDisplacement, hypot(position.x - base.x, position.y - base.y))
            }
        }
        
        guard maxDisplacement > Self.movementThreshold else {
            return false
        }
        
        hasTriggered = true
        return true
    }
    
    private mutating func mergeBaseline(
        _ joints: [VNHumanBodyPoseObservation.JointName: CGPoint]
    ) {
        guard baseline != nil else {
            baseline = joints
            return
        }
        
        for (joint, position) in joints {
            if let existing = baseline?[joint] {
                baseline?[joint] = CGPoint(x: (existing.x + position.x) / 2, y: (existing.y + position.y) / 2)
            } else {
                baseline?[joint] = position
            }
        }
    }
}
