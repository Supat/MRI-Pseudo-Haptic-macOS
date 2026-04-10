//
//  MRIPseudoHapticApp.swift
//
//  SwiftUI app entry point. Owns the pipeline singletons and tears them
//  down on termination so the Vimba transport layer unloads cleanly.
//

import SwiftUI

@main
struct MRIPseudoHapticApp: App {

    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("MRI Pseudo Haptic") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 640)
                .onDisappear {
                    appState.shutdown()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
