//
//  HistoryCoordinator.swift
//  UntitledMachine
//
//  The heart, wired together: watch the file, and quietly save a snapshot on
//  every change. Ties FileWatcher (FSEvents) to HistoryStore (SQLite).
//

import Foundation
import os

nonisolated final class HistoryCoordinator {

    let fileURL: URL
    let store: HistoryStore

    /// Called when a new snapshot is saved. Not called when a change is skipped
    /// because the content is unchanged. Runs on the watcher's queue.
    var onSnapshot: ((Snapshot) -> Void)?

    private var watcher: FileWatcher?
    private let log = Logger(subsystem: "com.tnantoka.UntitledMachine", category: "history")

    init(fileURL: URL, store: HistoryStore) {
        self.fileURL = fileURL.standardizedFileURL
        self.store = store
    }

    /// Captures the current content as the first version, then starts watching.
    func start() {
        capture()
        let watcher = FileWatcher(fileURL: fileURL) { [weak self] in
            self?.capture()
        }
        watcher.start()
        self.watcher = watcher
        log.info("watching: \(self.fileURL.path, privacy: .public)")
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Writes a version's content back to the file. The write is then recorded
    /// as a new version through FSEvents.
    func restore(to id: Int64) throws {
        guard let content = try store.content(id: id) else { return }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func capture() {
        do {
            let content = try readContent()
            if let snapshot = try store.appendSnapshot(content: content, createdAt: Date()) {
                log.info("saved snapshot #\(snapshot.id) (\(snapshot.byteCount) bytes)")
                onSnapshot?(snapshot)
            }
        } catch {
            log.error("capture failed: \(String(describing: error), privacy: .public)")
        }
    }

    // Treats a missing or unreadable file as empty (not yet created, mid-write).
    private func readContent() throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return "" }
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }
}
