//
//  StarterView.swift
//  OnYourMarks
//
//  Created by Felix on 11.06.26.
//

import SwiftUI

struct StarterView: View {
    @Bindable var vm = StarterViewModel()
    @FocusState private var fieldFocus: Bool
    
    var body: some View {
        ZStack {
            TrackBackground().opacity(0.9)
            VStack {
                StartTypeSelector(selection: $vm.config.startType).disabled(vm.isRunning)
                    .bold()
                Spacer()
                
                Text("Time to Ready")
                    .bold()
                DelaySlider(time: $vm.config.timeToReady, isRunning: vm.isRunning, range: 0...vm.config.sliderReadyClamp, step: 1, isFocused: $fieldFocus)
                if vm.config.startType == StartType.block {
                    Text("Time To Set")
                        .bold()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    DelaySlider(time: $vm.config.timeToSet, isRunning: vm.isRunning, range: 0...vm.config.sliderSetClamp, step: 1, isFocused: $fieldFocus)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Text("Time To Start")
                    .bold()
                DelaySlider(time: $vm.config.timeToStartMin, isRunning: vm.isRunning, range: 0...vm.config.sliderStartMinClamp, step: 0.1, isFocused: $fieldFocus)
                DelaySlider(time: $vm.config.timeToStartMax, isRunning: vm.isRunning, range: 0...vm.config.sliderStartMaxClamp, step: 0.1, isFocused: $fieldFocus)
                
                Spacer()
                
                if !fieldFocus {
                    StartControls(
                        isRunning: vm.isRunning,
                        onStart: { vm.start() },
                        onAbort: { vm.abort() }
                    )
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .trailing) {
                            if !vm.isRunning {
                                ResetButton(isEnabled: !vm.isRunning) {
                                    withAnimation(.easeInOut) { vm.resetConfig() }
                                }
                                .padding(.trailing, 8)
                            }
                        }
                }
                    
                
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
            .foregroundStyle(.chalk)
            .padding().animation(.easeInOut, value: vm.config.startType)
        }
    }
    
    private func resetWithAnimation() {
        withAnimation(.easeInOut) {
            vm.resetConfig()
        }
    }
}

#Preview {
    @Previewable @State var config = StarterViewModel()
    StarterView()
}
