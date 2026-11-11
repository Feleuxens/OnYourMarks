//
//  ReviewView.swift
//  OnYourMarks
//

import AVFoundation
import SwiftUI

/// Goes through a recorded start frame by frame: the video with the
/// skeletons drawn over it, the gun and the movements along the timeline,
/// and what was measured and decided.
struct ReviewView: View {
    let recorder: StartRecordingController

    @State private var model: ReviewModel
    @State private var saveFailed = false
    @State private var confirmsDelete = false
    @Environment(\.dismiss) private var dismiss

    init(recording: StartRecording, recorder: StartRecordingController) {
        self.recorder = recorder
        _model = State(initialValue: ReviewModel(recording: recording, videoURL: recorder.videoURL(of: recording)))
    }

    private var recording: StartRecording { model.recording }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 12) {
                ZStack {
                    PlayerLayerView(player: model.player)
                    SkeletonOverlay(
                        frame: model.tracking,
                        roster: model.timeline.roster,
                        falseStarters: model.timeline.falseStarters,
                        highlighted: model.highlighted
                    )
                }
                .aspectRatio(model.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("replayVideo")

                position

                ReplayScrubber(
                    timeline: model.timeline,
                    progress: model.progress,
                    highlighted: model.highlighted,
                    onScrub: { model.scrub(toFraction: $0) }
                )

                controls

                if !model.timeline.results.isEmpty {
                    ReactionTimes(
                        results: model.timeline.results,
                        selected: model.highlighted,
                        onSelect: select
                    )
                }
            }
            .padding()
            .foregroundStyle(.white)
        }
        .navigationTitle(Text(recording.date, format: .dateTime.day().month().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar { toolbar }
        .task {
            await model.load(tracking: await recorder.tracking(of: recording))
            // Opens where it matters: at the gun, or else at the first movement.
            if let start = model.timeline.gun?.best ?? model.timeline.results.first?.movement.earliest {
                model.jump(to: start)
            }
        }
        .onDisappear { model.pause() }
        .alert("The start could not be saved.", isPresented: $saveFailed) {
            Button("Ok") {}
        }
        .confirmationDialog("Delete this start?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.pause()
                recorder.delete(recording)
                dismiss()
            }
        }
    }

    /// Which frame is on screen and when it was captured against the gun.
    private var position: some View {
        HStack {
            Text("Frame \(model.currentFrame + 1) of \(model.timeline.frameCount)")
                .accessibilityIdentifier("replayFrame")

            Spacer()

            if let sinceGun = model.timeline.timeSinceGun(ofFrame: model.currentFrame) {
                let milliseconds = Int((abs(sinceGun) * 1000).rounded())

                if sinceGun < 0 {
                    Text("\(milliseconds) ms before the gun")
                } else {
                    Text("\(milliseconds) ms after the gun")
                }
            } else {
                Text("No gun")
            }
        }
        .font(.subheadline.monospacedDigit())
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button {
                if let gun = model.timeline.gun {
                    model.jump(to: gun.best)
                }
            } label: {
                Image(systemName: "flag.checkered")
            }
            .disabled(model.timeline.gun == nil)
            .accessibilityLabel("Go to the gun")
            .accessibilityIdentifier("replayGunButton")

            Button {
                model.step(by: -1)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .buttonRepeatBehavior(.enabled)
            .accessibilityLabel("Previous frame")
            .accessibilityIdentifier("replayBackButton")

            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(width: 36)
            }
            .accessibilityLabel(model.isPlaying ? Text("Pause") : Text("Play"))
            .accessibilityIdentifier("replayPlayButton")

            Button {
                model.step(by: 1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .buttonRepeatBehavior(.enabled)
            .accessibilityLabel("Next frame")
            .accessibilityIdentifier("replayForwardButton")

            Menu {
                Picker("Playback speed", selection: $model.rate) {
                    ForEach(ReviewModel.rates, id: \.self) { rate in
                        Text(Double(rate), format: .percent).tag(rate)
                    }
                }
            } label: {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
            .accessibilityLabel("Playback speed")
            .accessibilityIdentifier("replaySpeedMenu")
        }
        .font(.title2)
        .tint(.white)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            ShareLink(items: recorder.files(of: recording)) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Export")
            .accessibilityIdentifier("replayExportButton")

            if recorder.isSaved(recording) {
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete")
                .accessibilityIdentifier("replayDeleteButton")
            } else {
                Button("Save") {
                    save()
                }
                .accessibilityIdentifier("replaySaveButton")
            }
        }
    }

    /// Saving moves the files, so the video is opened again where it now
    /// is, at the frame that was on screen.
    private func save() {
        let frame = model.currentFrame
        let highlighted = model.highlighted
        model.pause()

        do {
            try recorder.save(recording)
        } catch {
            saveFailed = true
            return
        }

        let reopened = ReviewModel(recording: recording, videoURL: recorder.videoURL(of: recording))
        model = reopened

        Task {
            await reopened.load(tracking: await recorder.tracking(of: recording))
            reopened.highlighted = highlighted
            reopened.show(frame: frame)
        }
    }

    /// Picks an athlete out and shows where their movement began.
    private func select(_ result: AthleteStartResult) {
        if model.highlighted == result.athleteID, result.athleteID != nil {
            model.highlighted = nil
            return
        }

        model.highlighted = result.athleteID
        model.jump(to: result.movement.earliest)
    }
}

/// Shows a player's picture, nothing else.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
