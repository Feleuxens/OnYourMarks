//
//  ProbeView.swift
//  OnYourMarks
//

import AVFoundation
import SwiftUI

/// The probe mode: a measurement of the app's own timing against a light
/// that switches when it hears the gun. Not a start; nobody is judged.
struct ProbeView: View {
    @Bindable var vm: StarterViewModel
    @State private var regions: [ProbeRegion] = []

    var body: some View {
        ZStack {
            TrackBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("This is a measurement mode, not a start. Draw a rectangle on the picture around a light that switches when it hears the gun. The usual sequence plays, and the app measures when the light changed against the moment it expects the gun to be heard. If the app's times are right, the result is 0 ms.")
                        .font(.subheadline)

                    picture

                    HStack {
                        Button("Whole picture") {
                            regions = [ProbeRegion(rect: ProbeRegion.wholePicture)]
                        }
                        .accessibilityIdentifier("probeWholePictureButton")

                        Spacer()

                        Button("Clear", role: .destructive) {
                            regions = []
                        }
                        .disabled(regions.isEmpty)
                        .accessibilityIdentifier("probeClearButton")
                    }
                    .disabled(vm.isRunning)

                    if vm.isRunning {
                        Button("Stop measurement", role: .destructive) {
                            vm.abort()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("probeStopButton")
                    } else {
                        Button("Start measurement") {
                            vm.startProbe(regions: regions)
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(regions.isEmpty || !vm.cameraEnabled || vm.isCalibrating)
                        .accessibilityIdentifier("probeStartButton")
                    }

                    results
                }
                .padding()
            }
        }
        .foregroundStyle(.chalk)
        // The settings are disabled while a run goes on; this screen runs
        // the measurement and has to stop it, and disables its own controls.
        .environment(\.isEnabled, true)
        .navigationTitle("Timing probe")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var picture: some View {
        Group {
            if vm.cameraEnabled {
                ProbePreview(camera: vm.camera, regions: regions) { rect in
                    regions.append(ProbeRegion(rect: rect))
                }
                .allowsHitTesting(!vm.isRunning)
            } else {
                Button {
                    vm.enableCamera()
                } label: {
                    ZStack {
                        CameraPlaceholder()
                        Text("Turn on the camera")
                            .font(.headline)
                            .padding(.top, 90)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("probeCameraButton")
            }
        }
        // The upright picture, shown whole, so a rectangle on it is a part of it.
        .aspectRatio(9 / 16, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 420)
    }

    /// The last measurement, one line per region; only once the run is over.
    @ViewBuilder
    private var results: some View {
        if !vm.isRunning, let session = vm.lastSession, let probed = session.probeRegions {
            VStack(alignment: .leading, spacing: 8) {
                Text("Measured")
                    .font(.headline)

                ForEach(Array(probed.enumerated()), id: \.element.id) { index, region in
                    if let result = vm.probeResults.first(where: { $0.observation.regionID == region.id }) {
                        ProbeResultRow(number: index + 1, result: result)
                    } else {
                        Text("Region \(index + 1): no change seen")
                    }
                }

                if ReplayTimeline.gun(in: session) == nil {
                    Text("The gun did not fire, so there is nothing to measure against.")
                }
            }
            .font(.subheadline.monospacedDigit())
            .accessibilityIdentifier("probeResults")
        }
    }
}

/// One region's offset, with how far it may be off.
struct ProbeResultRow: View {
    let number: Int
    let result: ProbeResult

    var body: some View {
        let offset = result.offset

        VStack(alignment: .leading, spacing: 2) {
            Text("Region \(number): \(Self.milliseconds(offset.best)) ms after the gun")
            Text("between \(Self.milliseconds(offset.earliest)) and \(Self.milliseconds(offset.latest)) ms")
                .foregroundStyle(.chalk.opacity(0.7))
            Text("readout position \(result.observation.readoutPosition, format: .percent.precision(.fractionLength(0)))")
                .foregroundStyle(.chalk.opacity(0.7))
        }
    }

    /// One decimal: a frame at 240 fps lasts 4.2 ms.
    private static func milliseconds(_ seconds: TimeInterval) -> String {
        (seconds * 1000).formatted(.number.precision(.fractionLength(1)))
    }
}

nonisolated extension StartSession {
    /// The regions a measurement watched; nil for a start.
    var probeRegions: [ProbeRegion]? {
        events.firstNonNil { event in
            if case .probingStarted(let regions) = event.kind { regions } else { nil }
        }
    }

    /// What a measurement found when its run ended.
    var probeResults: [ProbeResult] {
        events.compactMap { event in
            if case .probeMeasured(let result) = event.kind { result } else { nil }
        }
    }
}

/// The camera's picture, whole, with the probed regions drawn on it. A
/// drag draws a new one.
struct ProbePreview: UIViewRepresentable {
    let camera: CameraController
    var regions: [ProbeRegion]
    var onDraw: (CGRect) -> Void

    func makeUIView(context: Context) -> ProbePreviewView {
        let view = ProbePreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspect
        view.regions = regions
        view.onDraw = onDraw
        return view
    }

    func updateUIView(_ view: ProbePreviewView, context: Context) {
        view.regions = regions
        view.onDraw = onDraw
    }
}

final class ProbePreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var regions: [ProbeRegion] = [] {
        didSet { setNeedsLayout() }
    }
    var onDraw: ((CGRect) -> Void)?

    /// A smaller rectangle is most likely a tap, not a region.
    private static let minimumSide: CGFloat = 0.01

    private let outlines = CAShapeLayer()
    private let draft = CAShapeLayer()
    private var numberLayers: [CATextLayer] = []
    private var dragStart: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)

        for shape in [outlines, draft] {
            shape.fillColor = UIColor.clear.cgColor
            shape.strokeColor = UIColor.systemCyan.cgColor
            shape.lineWidth = 2
            layer.addSublayer(shape)
        }
        draft.lineDashPattern = [6, 4]

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// From the upright picture to the layer, as the athletes' preview does it.
    private func layerPoint(_ p: CGPoint) -> CGPoint {
        previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: 1 - p.y, y: 1 - p.x))
    }

    private func picturePoint(_ p: CGPoint) -> CGPoint {
        let device = previewLayer.captureDevicePointConverted(fromLayerPoint: p)
        return CGPoint(x: 1 - device.y, y: 1 - device.x)
    }

    private func layerRect(_ rect: CGRect) -> CGRect {
        let a = layerPoint(CGPoint(x: rect.minX, y: rect.minY))
        let b = layerPoint(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            dragStart = location
        case .changed:
            if let dragStart {
                draft.path = UIBezierPath(rect: CGRect(origin: dragStart, size: .zero).union(CGRect(origin: location, size: .zero))).cgPath
            }
        case .ended:
            draft.path = nil
            guard let dragStart else { return }
            self.dragStart = nil

            let a = picturePoint(dragStart)
            let b = picturePoint(location)
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))

            if rect.width >= Self.minimumSide, rect.height >= Self.minimumSide {
                onDraw?(rect)
            }
        default:
            draft.path = nil
            dragStart = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlines.frame = bounds
        draft.frame = bounds

        let path = UIBezierPath()
        for region in regions {
            path.append(UIBezierPath(rect: layerRect(region.rect)))
        }
        outlines.path = path.cgPath

        while numberLayers.count < regions.count {
            let number = CATextLayer()
            number.fontSize = 14
            number.foregroundColor = UIColor.systemCyan.cgColor
            number.contentsScale = traitCollection.displayScale
            layer.addSublayer(number)
            numberLayers.append(number)
        }
        for (index, number) in numberLayers.enumerated() {
            number.isHidden = index >= regions.count
            guard index < regions.count else { continue }

            let rect = layerRect(regions[index].rect)
            number.string = (index + 1).formatted()
            number.frame = CGRect(x: rect.minX + 4, y: rect.minY + 2, width: 30, height: 18)
        }
        CATransaction.commit()
    }
}
