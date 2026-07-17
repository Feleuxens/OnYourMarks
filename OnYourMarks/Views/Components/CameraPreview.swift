//
//  CameraPreview.swift
//  OnYourMarks
//
//  Created by Felix on 17.07.26.
//

import SwiftUI
import AVFoundation
import Vision

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let joints: [VNHumanBodyPoseObservation.JointName: CGPoint]

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.joints = joints
        uiView.setNeedsLayout()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        var joints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:] {
            didSet { setNeedsLayout() }
        }

        private let overlayLayer = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            overlayLayer.strokeColor = UIColor.systemYellow.cgColor
            overlayLayer.fillColor = UIColor.white.cgColor
            overlayLayer.lineWidth = 3
            layer.addSublayer(overlayLayer)
        }
        required init?(coder: NSCoder) { fatalError() }

        private let connections: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
            (.neck, .leftShoulder), (.neck, .rightShoulder),
            (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
            (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
            (.neck, .root),
            (.root, .leftHip), (.root, .rightHip),
            (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
            (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        ]

        override func layoutSubviews() {
            super.layoutSubviews()
            overlayLayer.frame = bounds
            drawPose()
        }

        private func drawPose() {
            let path = UIBezierPath()

            func point(for joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
                guard let p = joints[joint] else { return nil }
                let devicePoint = CGPoint(x: 1 - p.y, y: 1 - p.x)
                return videoPreviewLayer.layerPointConverted(fromCaptureDevicePoint: devicePoint)
            }

            for (a, b) in connections {
                if let pa = point(for: a), let pb = point(for: b) {
                    path.move(to: pa)
                    path.addLine(to: pb)
                }
            }
            
            for joint in joints.keys {
                if let p = point(for: joint) {
                    path.move(to: CGPoint(x: p.x + 5, y: p.y))
                    path.addArc(withCenter: p, radius: 5, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                }
            }

            overlayLayer.path = path.cgPath
        }
    }
}
