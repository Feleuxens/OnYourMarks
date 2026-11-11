//
//  CameraPreview.swift
//  OnYourMarks
//
//  Created by Felix on 17.07.26.
//

import SwiftUI
import AVFoundation

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
        v.overlay.roster = roster
        v.overlay.falseStarters = falseStarters
        detector.onAthletes = { [weak v] athletes, phases in
            v?.overlay.phases = phases
            v?.overlay.athletes = athletes
        }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.overlay.roster = roster
        uiView.overlay.falseStarters = falseStarters
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

        let overlay = SkeletonOverlayView()

        override init(frame: CGRect) {
            super.init(frame: frame)

            // The preview crops the picture to fill the view, so the layer
            // has to say where a point of the picture ends up.
            overlay.pointConverter = { [weak self] p in
                let devicePoint = CGPoint(x: 1 - p.y, y: 1 - p.x)
                return self?.videoPreviewLayer.layerPointConverted(fromCaptureDevicePoint: devicePoint) ?? .zero
            }
            addSubview(overlay)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            overlay.frame = bounds
        }
    }
}
