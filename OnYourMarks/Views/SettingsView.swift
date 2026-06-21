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
    @FocusState private var fieldFocus: Bool

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
                    DelaySlider(title: "Time until \"On Your Marks\"", time: $vm.config.blockTimeToSet, isRunning: vm.isRunning, range: 0...vm.config.sliderReadyClamp, step: 1, isFocused: $fieldFocus)
                    DelaySlider(title: "Time until \"Set\"", time: $vm.config.blockTimeToSet, isRunning: vm.isRunning, range: 0...vm.config.sliderSetClamp, step: 1, isFocused: $fieldFocus)
                    DelaySlider(title: "Min time until Start", time: $vm.config.blockTimeToStartMin, isRunning: vm.isRunning, range: 0...vm.config.sliderStartMinClamp, step: 0.1, isFocused: $fieldFocus)
                    DelaySlider(title: "Max time until Start", time: $vm.config.blockTimeToStartMax, isRunning: vm.isRunning, range: 0...vm.config.sliderStartMaxClamp, step: 0.1, isFocused: $fieldFocus)
                }
                Section("Startsequenz (Hochstart)") {
                    DelaySlider(title: "Time until \"On Your Marks\"", time: $vm.config.standingTimeToReady, isRunning: vm.isRunning, range: 0...vm.config.sliderReadyClamp, step: 1, isFocused: $fieldFocus)
                    DelaySlider(title: "Min time until Start", time: $vm.config.standingTimeToStartMin, isRunning: vm.isRunning, range: 0...vm.config.sliderStartMinClamp, step: 0.1, isFocused: $fieldFocus)
                    DelaySlider(title: "Max time until Start", time: $vm.config.standingTimeToStartMax, isRunning: vm.isRunning, range: 0...vm.config.sliderStartMaxClamp, step: 0.1, isFocused: $fieldFocus)
                }
                
                Section {
                    Button("Auf Standard zurücksetzen", role: .destructive) {
                        vm.resetConfig()
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .disabled(vm.isRunning)            
        }
    }
}
