//
//  RecordingsView.swift
//  OnYourMarks
//

import SwiftUI

/// The recorded starts: the last one, which the next start replaces, and
/// the saved ones.
struct RecordingsView: View {
    let recorder: StartRecordingController

    var body: some View {
        ZStack {
            TrackBackground()

            if recorder.last == nil, recorder.saved.isEmpty {
                ContentUnavailableView(
                    "No recorded starts",
                    systemImage: "film",
                    description: Text("A start with the camera on is recorded and can be reviewed here.")
                )
                .foregroundStyle(.chalk)
            } else {
                List {
                    if let last = recorder.last {
                        Section {
                            row(for: last)
                        } header: {
                            Text("Last start")
                        } footer: {
                            Text("The next start replaces it unless you save it.")
                        }
                    }

                    if !recorder.saved.isEmpty {
                        Section("Saved") {
                            ForEach(recorder.saved) { recording in
                                row(for: recording)
                            }
                            .onDelete { offsets in
                                for recording in offsets.map({ recorder.saved[$0] }) {
                                    recorder.delete(recording)
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("recordingsList")
            }
        }
        .navigationTitle("Recorded starts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(for recording: StartRecording) -> some View {
        NavigationLink {
            ReviewView(recording: recording, recorder: recorder)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.date, format: .dateTime.day().month().year().hour().minute().second())

                Group {
                    if recording.session.outcome == .falseStart {
                        Text("False start")
                    } else {
                        Text("Reactions measured: \(recording.results.count)")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("recordingRow")
    }
}
