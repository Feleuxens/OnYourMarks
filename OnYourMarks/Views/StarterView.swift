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
        NavigationStack {
            
            ZStack {
                TrackBackground()
                VStack {
                    StartTypeSelector(selection: $vm.config.startType).disabled(vm.isRunning)
                    Spacer()
                    
                    if !fieldFocus {
                        StartControls(
                            isRunning: vm.isRunning,
                            onStart: { vm.start() },
                            onAbort: { vm.abort() }
                        )
                        .frame(maxWidth: .infinity)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView(vm: vm)
                    } label: {
                        Image(systemName: "gearshape").foregroundStyle(Color.graphite.opacity(0.7))
                    }.disabled(vm.isRunning).opacity(vm.isRunning ? 0.5 : 1)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fertig") { fieldFocus = false }
                }
            }
            .tint(.chalk)
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
