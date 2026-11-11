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
    let camera: CameraController
    let detector: PoseMotionDetector
    /// Its athletes are numbered in the picture; nil before the first start.
    var roster: AthleteRoster?
    /// Drawn in red for as long as they stay in view.
    var falseStarters: Set<AthleteID> = []

    func makeCoordinator() -> Coordinator {
        Coordinator(detector: detector)
    }
    
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = camera.session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        v.roster = roster
        v.falseStarters = falseStarters
        detector.onAthletes = { [weak v] athletes, phases in
            v?.phases = phases
            v?.athletes = athletes
        }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.roster = roster
        uiView.falseStarters = falseStarters
    }
    
    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.detector.onAthletes = nil
    }
    
    final class Coordinator {
        let detector: PoseMotionDetector
        init(detector: PoseMotionDetector) { self.detector = detector }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        var athletes: [TrackedAthlete] = [] {
            didSet { setNeedsLayout() }
        }

        /// How still the roster athletes are while a start watches them.
        var phases: [AthleteID: AthleteStability.Phase] = [:]

        var roster: AthleteRoster? {
            didSet { setNeedsLayout() }
        }

        var falseStarters: Set<AthleteID> = [] {
            didSet { setNeedsLayout() }
        }

        /// Athletes that are tracked and in the current frame.
        private let overlayLayer = CAShapeLayer()
        /// Everyone else: not confirmed yet, or drawn where last seen.
        private let uncertainLayer = CAShapeLayer()
        /// The athletes who false-started.
        private let falseStartLayer = CAShapeLayer()
        /// One per numbered athlete, reused between frames.
        private var numberLayers: [CATextLayer] = []

        private static let uncertainOpacity: Float = 0.4
        private static let jointRadius: CGFloat = 5
        private static let numberSize = CGSize(width: 28, height: 28)
        /// How far above the athlete's topmost joint the number sits.
        private static let numberGap: CGFloat = 10

        override init(frame: CGRect) {
            super.init(frame: frame)

            for skeletonLayer in [uncertainLayer, overlayLayer, falseStartLayer] {
                skeletonLayer.strokeColor = UIColor.systemYellow.cgColor
                skeletonLayer.fillColor = UIColor.white.cgColor
                skeletonLayer.lineWidth = 3
                layer.addSublayer(skeletonLayer)
            }
            uncertainLayer.opacity = Self.uncertainOpacity
            falseStartLayer.strokeColor = UIColor.systemRed.cgColor
            falseStartLayer.lineWidth = 5
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
            draw()
        }

        /// From Vision's normalized, upright picture to this view.
        private func layerPoint(_ p: CGPoint) -> CGPoint {
            let devicePoint = CGPoint(x: 1 - p.y, y: 1 - p.x)
            return videoPreviewLayer.layerPointConverted(fromCaptureDevicePoint: devicePoint)
        }

        private func skeleton(of athletes: [TrackedAthlete]) -> CGPath {
            let path = UIBezierPath()

            for athlete in athletes {
                let joints = athlete.pose.joints.mapValues(layerPoint)

                for (a, b) in connections {
                    if let pa = joints[a], let pb = joints[b] {
                        path.move(to: pa)
                        path.addLine(to: pb)
                    }
                }

                for p in joints.values {
                    path.move(to: CGPoint(x: p.x + Self.jointRadius, y: p.y))
                    path.addArc(withCenter: p, radius: Self.jointRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                }
            }
            return path.cgPath
        }

        private func draw() {
            let visible = athletes.filter { $0.state != .lost }
            let flagged = visible.filter { falseStarters.contains($0.id) }
            let others = visible.filter { !falseStarters.contains($0.id) }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for sublayer in [uncertainLayer, overlayLayer, falseStartLayer] {
                sublayer.frame = bounds
            }
            overlayLayer.path = skeleton(of: others.filter { $0.state == .tracked && $0.isVisible })
            uncertainLayer.path = skeleton(of: others.filter { !($0.state == .tracked && $0.isVisible) })
            falseStartLayer.path = skeleton(of: flagged)
            drawNumbers(for: visible)
            CATransaction.commit()
        }

        /// Puts each roster athlete's number above their head.
        private func drawNumbers(for athletes: [TrackedAthlete]) {
            let numbered = athletes.compactMap { athlete in
                roster?.position(of: athlete.id).map { (athlete: athlete, position: $0) }
            }

            while numberLayers.count < numbered.count {
                let numberLayer = CATextLayer()
                numberLayer.fontSize = 18
                numberLayer.alignmentMode = .center
                numberLayer.foregroundColor = UIColor.black.cgColor
                numberLayer.cornerRadius = Self.numberSize.height / 2
                numberLayer.contentsScale = traitCollection.displayScale
                layer.addSublayer(numberLayer)
                numberLayers.append(numberLayer)
            }

            for (index, numberLayer) in numberLayers.enumerated() {
                guard index < numbered.count else {
                    numberLayer.isHidden = true
                    continue
                }

                let (athlete, position) = numbered[index]
                let joints = athlete.pose.joints.values.map(layerPoint)
                let top = joints.map { $0.y }.min() ?? 0
                let middle = joints.map { $0.x }.reduce(0, +) / CGFloat(max(joints.count, 1))
                let isFalseStarter = falseStarters.contains(athlete.id)

                numberLayer.isHidden = false
                numberLayer.string = position.formatted()
                // Green once the athlete holds still.
                let color: UIColor = isFalseStarter ? .systemRed
                    : phases[athlete.id] == .stable ? .systemGreen : .systemYellow
                numberLayer.backgroundColor = color.cgColor
                numberLayer.foregroundColor = (isFalseStarter ? UIColor.white : UIColor.black).cgColor
                numberLayer.frame = CGRect(
                    origin: CGPoint(
                        x: middle - Self.numberSize.width / 2,
                        y: top - Self.numberGap - Self.numberSize.height
                    ),
                    size: Self.numberSize
                )
            }
        }
    }
}
