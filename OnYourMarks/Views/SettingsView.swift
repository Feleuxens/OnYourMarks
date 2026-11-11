//
//  SettingsView.swift
//  OnYourMarks
//
//  Created by Felix on 21.06.26.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var vm: StarterViewModel
    @FocusState private var focusedSlider: UInt8?
    
    var body: some View {
        ZStack {
            TrackBackground()
            Form {
                AudioOutputSection(vm: vm)
                
                Section("Signal") {
                    Picker("Sound", selection: $vm.config.soundTheme) {
                        ForEach(SoundTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    // Loading another theme would interrupt the calibration's clicks.
                    .disabled(vm.isCalibrating)
                }
                
                Section {
                    Picker("Camera mount", selection: $vm.config.cameraMount) {
                        Text("Tripod").tag(CameraMount.tripod)
                        Text("Handheld").tag(CameraMount.handheld)
                    }
                    .accessibilityIdentifier("cameraMountPicker")
                    
                    Picker("Frame rate", selection: $vm.config.frameRate) {
                        ForEach(CameraFrameRate.allCases, id: \.self) { frameRate in
                            Text("\(frameRate.rawValue) fps").tag(frameRate)
                        }
                    }
                    .accessibilityIdentifier("frameRatePicker")
                } header: {
                    Text("Camera")
                } footer: {
                    Text("Handheld compensates for small movements of the camera. A tripod is more precise. A higher frame rate times a movement more finely but needs more light; if the camera doesn't reach it, its fastest rate is used.")
                }
                
                Section("Start sequence (block)") {
                    DelaySlider(id: 1, title: "Time until \"On Your Marks\"", time: $vm.config.blockTimeToReady, range: StartConfig.readyRange, step: 1, focusedSlider: $focusedSlider)
                    DelaySlider(id: 2, title: "Time until \"Set\"", time: $vm.config.blockTimeToSet, range: StartConfig.setRange, step: 1, focusedSlider: $focusedSlider)
                    DelaySlider(id: 3, title: "Min time until Start", time: $vm.config.blockTimeToStartMin, range: StartConfig.startRange, step: 0.1, focusedSlider: $focusedSlider)
                    DelaySlider(id: 4, title: "Max time until Start", time: $vm.config.blockTimeToStartMax, range: StartConfig.startRange, step: 0.1, focusedSlider: $focusedSlider)
                }
                Section("Start sequence (standing)") {
                    DelaySlider(id: 5, title: "Time until \"On Your Marks\"", time: $vm.config.standingTimeToReady, range: StartConfig.readyRange, step: 1, focusedSlider: $focusedSlider)
                    DelaySlider(id: 6, title: "Min time until Start", time: $vm.config.standingTimeToStartMin, range: StartConfig.startRange, step: 0.1, focusedSlider: $focusedSlider)
                    DelaySlider(id: 7, title: "Max time until Start", time: $vm.config.standingTimeToStartMax, range: StartConfig.startRange, step: 0.1, focusedSlider: $focusedSlider)
                }
                
                Section {
                    Button("Reset to defaults", role: .destructive) {
                        withAnimation(.easeInOut) { vm.resetConfig() }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .disabled(vm.isRunning)
        }
    }
}
