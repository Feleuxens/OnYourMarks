//
//  StarterView.swift
//  OnYourMarks
//
//  Created by Felix on 11.06.26.
//

import SwiftUI

struct StarterView: View {
    @State private var vm = StarterViewModel()
    @Environment(\.scenePhase) private var scenePhase
    
    private var shouldStayAwake: Bool {
        vm.cameraEnabled || vm.isRunning
    }
    
    var body: some View {
        @Bindable var vm = vm
        
        NavigationStack {
            
            ZStack {
                TrackBackground()
                VStack {
                    StartTypeSelector(selection: $vm.config.startType).disabled(vm.isRunning)
                    
                    Spacer()
                    Group {
                        if vm.cameraEnabled {
                            CameraPreview(detector: vm.cameraDetector)
                                .aspectRatio(3/4, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        } else {
                            CameraPlaceholder()
                        }
                    }
                    .aspectRatio(3/4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .bottom) {
                        CameraToggleButton(isOn: vm.cameraEnabled) {
                            if vm.cameraEnabled { vm.disableCamera() }
                            else { vm.enableCamera() }
                        }
                        .disabled(vm.isRunning)
                        .opacity(vm.isRunning ? 0.5 : 1)
                        .padding(.bottom, 8)
                    }
                    
                    Spacer()
                    
                    StartControls(
                        isRunning: vm.isRunning,
                        onStart: { vm.start() },
                        onAbort: { vm.abort() }
                    )
                    .frame(maxWidth: .infinity)
    
                    
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.chalk)
                .padding().animation(.easeInOut, value: vm.config.startType)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView(vm: vm)
                    } label: {
                        Image(systemName: "gearshape").foregroundStyle(Color.graphite.opacity(0.7))
                    }.disabled(vm.isRunning).opacity(vm.isRunning ? 0.5 : 1).buttonStyle(.plain)
                }
            }
            .tint(.chalk)
            .toolbarColorScheme(.light, for: .automatic)
        }
        .onChange(of: shouldStayAwake) { _, stayAwake in
            UIApplication.shared.isIdleTimerDisabled = stayAwake
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .alert("Camera access required", isPresented: $vm.cameraPermissionDenied) {
            Button("Open Settings") {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable camera access in Settings to use false-start detection.")
        }
        .alert(
            "OnYourMarks Error",
            isPresented: Binding(
                get: {
                    vm.errorMessage != nil
                },
                set: {
                    presented in if !presented {
                        vm.errorMessage = nil
                    }
                }
            )
        ) {
            Button("Ok") {
                vm.errorMessage = nil
            }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .onChange(of: scenePhase) { _, newPase in
            guard newPase == .active else { return }
            
            if vm.isRunning {
                vm.abort()
            }
            if vm.cameraEnabled {
                vm.disableCamera()
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
    
    private func resetWithAnimation() {
        withAnimation(.easeInOut) {
            vm.resetConfig()
        }
    }
}

#Preview {
    StarterView()
}
