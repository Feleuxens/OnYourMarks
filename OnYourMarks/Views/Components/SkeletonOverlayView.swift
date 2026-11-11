//
//  SkeletonOverlayView.swift
//  OnYourMarks
//

import SwiftUI
import Vision

/// Draws the athletes' skeletons and numbers over a picture: the live
/// preview or a frame of a recording.
final class SkeletonOverlayView: UIView {
    var athletes: [TrackedAthlete] = [] {
        didSet { setNeedsLayout() }
    }

    /// How still the roster athletes are while a start watches them.
    var phases: [AthleteID: AthleteStability.Phase] = [:] {
        didSet { setNeedsLayout() }
    }

    var roster: AthleteRoster? {
        didSet { setNeedsLayout() }
    }

    var falseStarters: Set<AthleteID> = [] {
        didSet { setNeedsLayout() }
    }

    /// Stands out while everyone else fades; nil shows all alike.
    var highlighted: AthleteID? {
        didSet { setNeedsLayout() }
    }

    /// From Vision's normalized, upright picture to this view. Nil if the
    /// view covers exactly the picture.
    var pointConverter: ((CGPoint) -> CGPoint)? {
        didSet { setNeedsLayout() }
    }

    /// Athletes that are tracked and in the current frame.
    private let overlayLayer = CAShapeLayer()
    /// Everyone else: not confirmed yet, or drawn where last seen.
    private let uncertainLayer = CAShapeLayer()
    /// The athletes who false-started.
    private let falseStartLayer = CAShapeLayer()
    /// The outline that makes the highlighted athlete stand out.
    private let highlightLayer = CAShapeLayer()
    /// One per numbered athlete, reused between frames.
    private var numberLayers: [CATextLayer] = []

    private static let uncertainOpacity: Float = 0.4
    private static let jointRadius: CGFloat = 5
    private static let numberSize = CGSize(width: 28, height: 28)
    /// How far above the athlete's topmost joint the number sits.
    private static let numberGap: CGFloat = 10

    override init(frame: CGRect) {
        super.init(frame: frame)

        isUserInteractionEnabled = false
        backgroundColor = .clear

        highlightLayer.strokeColor = UIColor.white.cgColor
        highlightLayer.fillColor = UIColor.clear.cgColor
        highlightLayer.lineWidth = 9
        highlightLayer.lineCap = .round
        layer.addSublayer(highlightLayer)

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

    private func layerPoint(_ p: CGPoint) -> CGPoint {
        if let pointConverter {
            return pointConverter(p)
        }
        // Vision counts y from the bottom.
        return CGPoint(x: bounds.minX + p.x * bounds.width, y: bounds.minY + (1 - p.y) * bounds.height)
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

        // With one athlete picked out, the rest step back.
        func isCertain(_ athlete: TrackedAthlete) -> Bool {
            athlete.state == .tracked && athlete.isVisible && (highlighted == nil || highlighted == athlete.id)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [highlightLayer, uncertainLayer, overlayLayer, falseStartLayer] {
            sublayer.frame = bounds
        }
        highlightLayer.path = skeleton(of: visible.filter { $0.id == highlighted })
        overlayLayer.path = skeleton(of: others.filter(isCertain))
        uncertainLayer.path = skeleton(of: others.filter { !isCertain($0) })
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
            numberLayer.borderColor = UIColor.white.cgColor
            numberLayer.borderWidth = athlete.id == highlighted ? 3 : 0
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

/// The skeletons of one recorded frame, over a view that shows exactly
/// that frame's picture.
struct SkeletonOverlay: UIViewRepresentable {
    var frame: TrackingFrame?
    var roster: AthleteRoster?
    var falseStarters: Set<AthleteID> = []
    var highlighted: AthleteID?

    func makeUIView(context: Context) -> SkeletonOverlayView {
        SkeletonOverlayView()
    }

    func updateUIView(_ view: SkeletonOverlayView, context: Context) {
        view.athletes = frame?.athletes ?? []
        view.phases = frame?.phases ?? [:]
        view.roster = roster
        view.falseStarters = falseStarters
        view.highlighted = highlighted
    }
}
