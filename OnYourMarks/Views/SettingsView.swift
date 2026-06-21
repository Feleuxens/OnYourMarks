//
//  SettingsView.swift
//  OnYourMarks
//
//  Created by Felix on 21.06.26.
//

// Views/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @Bindable var vm: StarterViewModel
    @FocusState private var focusedSlider: UInt8?
    
    var body: some View {
        ZStack {
            TrackBackground()
            Form {
                Section("Signal") {
                    Picker("Ton", selection: $vm.config.soundTheme) {
                        ForEach(SoundTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                }
                
                Section("Startsequenz (Block)") {
                    DelaySlider(id: 1, title: "Time until \"On Your Marks\"", time: $vm.config.blockTimeToReady, isRunning: vm.isRunning, range: 0...vm.config.sliderReadyClamp, step: 1, focusedSlider: $focusedSlider)
                    DelaySlider(id: 2, title: "Time until \"Set\"", time: $vm.config.blockTimeToSet, isRunning: vm.isRunning, range: 0...vm.config.sliderSetClamp, step: 1, focusedSlider: $focusedSlider)
                    DelaySlider(id: 3, title: "Min time until Start", time: $vm.config.blockTimeToStartMin, isRunning: vm.isRunning, range: 0...vm.config.sliderStartMinClamp, step: 0.1, focusedSlider: $focusedSlider)
                    DelaySlider(id: 4, title: "Max time until Start", time: $vm.config.blockTimeToStartMax, isRunning: vm.isRunning, range: 0...vm.config.sliderStartMaxClamp, step: 0.1, focusedSlider: $focusedSlider)
                }
                Section("Startsequenz (Hochstart)") {
                    DelaySlider(id: 5, title: "Time until \"On Your Marks\"", time: $vm.config.standingTimeToReady, isRunning: vm.isRunning, range: 0...vm.config.sliderReadyClamp, step: 1, focusedSlider: $focusedSlider)
                    DelaySlider(id: 6, title: "Min time until Start", time: $vm.config.standingTimeToStartMin, isRunning: vm.isRunning, range: 0...vm.config.sliderStartMinClamp, step: 0.1, focusedSlider: $focusedSlider)
                    DelaySlider(id: 7, title: "Max time until Start", time: $vm.config.standingTimeToStartMax, isRunning: vm.isRunning, range: 0...vm.config.sliderStartMaxClamp, step: 0.1, focusedSlider: $focusedSlider)
                }
                
                Section {
                    Button("Auf Standard zurücksetzen", role: .destructive) {
                        withAnimation(.easeInOut) { vm.resetConfig() }
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .disabled(vm.isRunning)
        }
    }
}
