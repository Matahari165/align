//
//  AlignApp.swift
//  Align
//
//  Created by Jérémy Delloume on 28/08/2026.
//

import SwiftUI

enum AlignTheme {
    static let canvas = Color(red: 0.086, green: 0.09, blue: 0.082)
    static let elevated = Color(red: 0.125, green: 0.13, blue: 0.118)
    static let copper = Color(red: 0.76, green: 0.48, blue: 0.29)
    static let ivory = Color(red: 0.95, green: 0.93, blue: 0.87)
    static let quiet = Color(red: 0.64, green: 0.63, blue: 0.58)
    static let hairline = Color.white.opacity(0.10)
}

@main
struct AlignApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        Window("Align", id: "main") {
            ContentView(appModel: appModel)
                .tint(AlignTheme.copper)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 760, height: 560)

        Window("Statistiques", id: "statistics") {
            StatisticsView(history: appModel.history) {
                NSApp.keyWindow?.close()
            }
            .tint(AlignTheme.copper)
            .preferredColorScheme(.dark)
        }
        .defaultSize(width: 720, height: 560)

        Window("Réglages", id: "settings") {
            SettingsView(appModel: appModel, camera: appModel.camera) {
                NSApp.keyWindow?.close()
            }
            .tint(AlignTheme.copper)
            .preferredColorScheme(.dark)
        }
        .defaultSize(width: 620, height: 560)

        MenuBarExtra {
            StatusMenuView(camera: appModel.camera, history: appModel.history, onQuit: appModel.quit)
        } label: {
            StatusMenuLabel(camera: appModel.camera)
        }
        .menuBarExtraStyle(.menu)
    }
}
