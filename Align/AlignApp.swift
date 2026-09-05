//
//  AlignApp.swift
//  Align
//
//  Created by Jérémy Delloume on 28/08/2026.
//

import AppKit
import SwiftUI

/// The data used to choose the canonical process is kept separate from
/// AppKit so the policy remains deterministic and straightforward to test.
struct AlignInstanceDescriptor: Equatable {
    let processIdentifier: Int32
    let executableModifiedAt: Date?
    let bundleVersion: String?
    let launchDate: Date?
    let isCurrentProcess: Bool

    /// Returns true when `lhs` is the process that should remain alive.
    /// A newer executable wins; existing processes win only when all build
    /// metadata is tied, preventing two simultaneous launches of one build.
    static func prefers(_ lhs: Self, over rhs: Self) -> Bool {
        if let result = compare(lhs.executableModifiedAt, rhs.executableModifiedAt),
           result != .orderedSame {
            return result == .orderedDescending
        }
        if let result = compareVersions(lhs.bundleVersion, rhs.bundleVersion),
           result != .orderedSame {
            return result == .orderedDescending
        }
        if let lhsLaunchDate = lhs.launchDate,
           let rhsLaunchDate = rhs.launchDate,
           lhsLaunchDate != rhsLaunchDate {
            // An older launch is normally the already-established instance.
            return lhsLaunchDate < rhsLaunchDate
        }
        if lhs.isCurrentProcess != rhs.isCurrentProcess {
            return !lhs.isCurrentProcess
        }
        return lhs.processIdentifier < rhs.processIdentifier
    }

    private static func compare(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (.some, .none):
            .orderedDescending
        case (.none, .some):
            .orderedAscending
        case (.none, .none):
            nil
        }
    }

    private static func compareVersions(_ lhs: String?, _ rhs: String?) -> ComparisonResult? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            lhs.compare(rhs, options: [.numeric, .caseInsensitive])
        case (.some, .none):
            .orderedDescending
        case (.none, .some):
            .orderedAscending
        case (.none, .none):
            nil
        }
    }
}

private enum AlignSingleInstance {
    private static let terminationTimeout: TimeInterval = 2

    private struct RunningInstance {
        let application: NSRunningApplication
        let descriptor: AlignInstanceDescriptor
    }

    static func enforce() {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            // A bare executable launched outside an app bundle has no safe
            // bundle identity to compare. Launch Services cannot enforce it.
            return
        }

        let current = AlignInstanceDescriptor(
            processIdentifier: currentProcessID,
            executableModifiedAt: modificationDate(of: Bundle.main.executableURL),
            bundleVersion: bundleVersion(from: Bundle.main),
            launchDate: nil,
            isCurrentProcess: true
        )
        let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentProcessID }
            .map { app in
                RunningInstance(
                    application: app,
                    descriptor: AlignInstanceDescriptor(
                        processIdentifier: app.processIdentifier,
                        executableModifiedAt: modificationDate(of: app.executableURL),
                        bundleVersion: bundleVersion(for: app),
                        launchDate: app.launchDate,
                        isCurrentProcess: false
                    )
                )
            }

        guard !existing.isEmpty else { return }

        let winner = ([current] + existing.map(\.descriptor)).reduce(current) { best, candidate in
            AlignInstanceDescriptor.prefers(candidate, over: best) ? candidate : best
        }

        if winner.processIdentifier == currentProcessID {
            let losingApplications = existing
                .filter { $0.descriptor.processIdentifier != winner.processIdentifier }
                .map(\.application)
            for application in losingApplications {
                _ = application.terminate()
            }

            // Camera ownership must never overlap. If an older build ignores
            // normal termination, this new process exits instead of starting
            // a second capture pipeline.
            guard waitForTermination(of: losingApplications) else {
                NSApplication.shared.terminate(nil)
                return
            }
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        } else if let winnerApplication = existing.first(where: {
            $0.descriptor.processIdentifier == winner.processIdentifier
        })?.application {
            _ = winnerApplication.activate(options: [.activateAllWindows])
            NSApplication.shared.terminate(nil)
        }
    }

    private static func waitForTermination(of applications: [NSRunningApplication]) -> Bool {
        let deadline = Date().addingTimeInterval(terminationTimeout)
        while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return applications.allSatisfy(\.isTerminated)
    }

    private static func modificationDate(of executableURL: URL?) -> Date? {
        guard let executableURL else { return nil }
        return try? executableURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
    }

    private static func bundleVersion(from bundle: Bundle) -> String? {
        (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    private static func bundleVersion(for application: NSRunningApplication) -> String? {
        let bundleURL = application.bundleURL
            ?? application.executableURL?.deletingLastPathComponent()
                .deletingLastPathComponent()
        guard let bundle = bundleURL.flatMap(Bundle.init(url:)) else { return nil }
        return bundleVersion(from: bundle)
    }
}

private final class AlignAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AlignSingleInstance.enforce()
    }
}

enum AlignTheme {
    // The icon uses a deep navy field with a single luminous teal mark. The UI
    // keeps that relationship: dark neutrals carry the surface, teal signals
    // reliable state and action, and amber is reserved for posture deviations.
    static let canvas = Color(red: 0.025, green: 0.075, blue: 0.105)
    static let elevated = Color(red: 0.045, green: 0.125, blue: 0.155)
    static let surface = Color(red: 0.070, green: 0.175, blue: 0.195)
    static let accent = Color(red: 0.145, green: 0.805, blue: 0.825)
    static let accentStrong = Color(red: 0.075, green: 0.590, blue: 0.650)
    static let accentSoft = Color(red: 0.680, green: 0.940, blue: 0.920)
    static let attention = Color(red: 0.980, green: 0.690, blue: 0.350)
    static let ivory = Color(red: 0.900, green: 0.955, blue: 0.945)
    static let quiet = Color(red: 0.580, green: 0.710, blue: 0.720)
    static let hairline = Color(red: 0.350, green: 0.820, blue: 0.820).opacity(0.18)
}

@main
struct AlignApp: App {
    @NSApplicationDelegateAdaptor(AlignAppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        Window("Align", id: "main") {
            ContentView(appModel: appModel)
                .tint(AlignTheme.accent)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 760, height: 560)

        Window("Statistiques", id: "statistics") {
            StatisticsView(history: appModel.history) {
                NSApp.keyWindow?.close()
            }
            .tint(AlignTheme.accent)
            .preferredColorScheme(.dark)
        }
        .defaultSize(width: 720, height: 560)

        Window("Réglages", id: "settings") {
            SettingsView(appModel: appModel, camera: appModel.camera) {
                NSApp.keyWindow?.close()
            }
            .tint(AlignTheme.accent)
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
