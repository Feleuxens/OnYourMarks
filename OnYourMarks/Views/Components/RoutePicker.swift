//
//  RoutePicker.swift
//  OnYourMarks
//

import AVKit
import SwiftUI

/// The system's output picker. Changes the route for all apps, not only this one.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .label
        picker.prioritizesVideoDevices = false
        return picker
    }
    
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
