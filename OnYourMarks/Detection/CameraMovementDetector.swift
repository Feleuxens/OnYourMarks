//
//  CameraMovementDetector.swift
//  OnYourMarks
//
//  Created by Felix on 17.07.26.
//

import AVFoundation
import Vision
import QuartzCore

@Observable
final class CameraMovementDetector: NSObject, MovementDetector {
    var detectedJoints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
    
    var onMovement: ((TimeInterval) -> Void)?

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.movement.detector")
    private let poseRequest = VNDetectHumanBodyPoseRequest()

    private var isMonitoring = false
    private var baseline: [VNHumanBodyPoseObservation.JointName: CGPoint]?
    private var baselineFrames = 0
    private var hasTriggered = false

    private let jointsOfInterest: [VNHumanBodyPoseObservation.JointName] =
        [
            .root,
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

    override init() {
        super.init()
        configureSession()
        print("Detector init, inputs: \(session.inputs.count), outputs: \(session.outputs.count)")
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
    }

    func startSession() {
        queue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            print("Session läuft: \(self.session.isRunning)")
        }
    }
    func stopSession() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func startMonitoring() {
        queue.async { [weak self] in
            self?.baseline = nil
            self?.baselineFrames = 0
            self?.hasTriggered = false
            self?.isMonitoring = true
        }
    }
    func stopMonitoring() {
        queue.async { [weak self] in self?.isMonitoring = false }
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
            self?.detectedJoints = snapshot
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
