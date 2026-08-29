//
//  AlignApp.swift
//  Align
//
//  Created by Jérémy Delloume on 28/08/2026.
//

import SwiftUI

@main
struct AlignApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        Window("Align", id: "main") {
            ContentView(camera: appModel.camera)
        }
        .defaultSize(width: 760, height: 560)

        MenuBarExtra {
            StatusMenuView(camera: appModel.camera, onQuit: appModel.quit)
        } label: {
            StatusMenuLabel(camera: appModel.camera)
        }
        .menuBarExtraStyle(.menu)
    }
}
