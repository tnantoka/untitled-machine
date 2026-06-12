//
//  AppDelegate.swift
//  UntitledMachine
//
//  Created by Tatsuya Tobioka on 2026/06/11.
//

import Cocoa
import os

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    // Static because it's used across threads (Logger is Sendable).
    static let log = Logger(subsystem: "com.tnantoka.UntitledMachine", category: "app")
    private var coordinator: HistoryCoordinator?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        startWatchingIfConfigured()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        coordinator?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // No UI yet: the watched file is configured via UserDefaults for now.
    // e.g. defaults write com.tnantoka.UntitledMachine watchedFilePath "$HOME/Untitled.txt"
    private func startWatchingIfConfigured() {
        guard let path = UserDefaults.standard.string(forKey: "watchedFilePath"), !path.isEmpty else {
            Self.log.notice("No file configured. Set one with: defaults write com.tnantoka.UntitledMachine watchedFilePath <path>")
            return
        }

        do {
            let store = try HistoryStore(url: databaseURL())
            let coordinator = HistoryCoordinator(fileURL: URL(fileURLWithPath: path), store: store)
            coordinator.onSnapshot = { snapshot in
                AppDelegate.log.info("recorded version #\(snapshot.id) (\(snapshot.byteCount) bytes)")
            }
            coordinator.start()
            self.coordinator = coordinator
        } catch {
            Self.log.error("startup failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// ~/Library/Application Support/UntitledMachine/history.db
    private func databaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("UntitledMachine", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.db")
    }
}
