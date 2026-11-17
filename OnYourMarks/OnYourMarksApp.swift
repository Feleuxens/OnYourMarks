//
//  OnYourMarksApp.swift
//  OnYourMarks
//
//  Created by Felix on 11.06.26.
//

import SwiftUI

@main
struct OnYourMarksApp: App {
    /// App-wide, so phones stay synchronized when the screen that shows
    /// them is closed. Nothing touches the network until it is started.
    @State private var nodes = NodeSession()

    var body: some Scene {
        WindowGroup {
            StarterView()
                .environment(nodes)
        }
    }
}
