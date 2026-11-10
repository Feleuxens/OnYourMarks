//
//  AudioOutputSection.swift
//  OnYourMarks
//

import SwiftUI

struct AudioOutputSection: View {
    @Bindable var vm: StarterViewModel
    
    var body: some View {
        Section {
            Picker("Output", selection: $vm.config.audioOutput) {
                Text("Automatic").tag(AudioOutput.automatic)
                Text("iPhone speaker").tag(AudioOutput.iPhoneSpeaker)
            }
            .accessibilityIdentifier("outputPicker")
            // Switching the output would end the session the calibration runs on.
            .disabled(vm.isCalibrating)
            
            if vm.config.audioOutput == .automatic {
                LabeledContent("Current output") {
                    HStack {
                        Text(vm.currentOutput?.name ?? String(localized: "Unknown"))
                        RoutePicker()
                            .frame(width: 32, height: 32)
                            .accessibilityLabel("Choose output device")
                    }
                }
            }
            
            calibration
        } header: {
            Text("Audio output")
        } footer: {
            if vm.canCalibrateOutput {
                Text("Calibration plays the start signal six times and listens with the microphone. Turn the volume up and hold the headphones or speaker next to the iPhone, in a quiet room.")
            } else {
                Text("The iPhone speaker reports its latency precisely, so it needs no calibration.")
            }
        }
        .onAppear { vm.refreshCurrentOutput() }
    }
    
    @ViewBuilder
    private var calibration: some View {
        if let calibration = vm.activeCalibration {
            LabeledContent("Latency correction") {
                // The uncertainty the timing actually applies, not the raw spread.
                Text("\(milliseconds(calibration.correction)) ms ± \(milliseconds(OutputTiming.uncertainty(calibrated: calibration))) ms")
                    .monospacedDigit()
            }
            LabeledContent("Calibrated", value: calibration.date.formatted(date: .abbreviated, time: .shortened))
            
            Button("Remove calibration", role: .destructive) {
                vm.removeCalibration(calibration)
            }
        } else if vm.canCalibrateOutput {
            LabeledContent("Latency correction", value: String(localized: "Not calibrated"))
        } else {
            LabeledContent("Latency correction", value: String(localized: "Not needed"))
        }
        
        Button {
            vm.calibrateOutput()
        } label: {
            if vm.isCalibrating {
                HStack {
                    Text("Calibrating…")
                    Spacer()
                    ProgressView()
                }
            } else {
                Text("Calibrate output")
            }
        }
        .disabled(vm.isCalibrating || !vm.canCalibrateOutput)
        .accessibilityIdentifier("calibrateButton")
    }
    
    private func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }
}
