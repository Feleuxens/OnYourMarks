//
//  CameraPermission.swift
//  OnYourMarks
//
//  Created by Felix on 17.07.26.
//

import AVFoundation

enum CameraPermission {
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:     return true
        case .notDetermined:  return await AVCaptureDevice.requestAccess(for: .video)
        default:              return false
        }
    }
}
