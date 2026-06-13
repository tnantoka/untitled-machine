//
//  HistoryCoordinator.swift
//  UntitledMachine
//
//  The heart, wired together: watch the file, and quietly save a snapshot when
//  editing settles. Ties FileWatcher (FSEvents) to HistoryStore (SQLite).
//
//  Captures are debounced: instead of one snapshot per save, we wait until the
//  file has been quiet for `debounceInterval` and snapshot once. This thins out
//  rapid-fire saves (keeping the version list and storage manageable). Tuning
//  the scale behaviour later is just a matter of changing that interval.
//

import Foundation
import os

nonisolated final class HistoryCoordinator: @unchecked Sendable {

    let fileURL: URL
    let store: HistoryStore

    /// Called when a new snapshot is saved. Not called when a change is skipped
    /// because the content is unchanged. May run on a background queue.
    var onSnapshot: ((Snapshot) -> Void)?

    private let debounceInterval: TimeInterval
    private var watcher: FileWatcher?
    // Capture scheduling/state lives only on this queue, so it stays serialized.
    private let captureQueue = DispatchQueue(label: "com.tnantoka.UntitledMachine.capture")
    private var pendingCapture: DispatchWorkItem?
    private let log = Logger(subsystem: "com.tnantoka.UntitledMachine", category: "history")

    init(fileURL: URL, store: HistoryStore, debounceInterval: TimeInterval = 2) {
        self.fileURL = fileURL.standardizedFileURL
        self.store = store
        self.debounceInterval = debounceInterval
    }

    /// Captures the current content as the first version, then starts watching.
    func start() {
        captureNow()
        let watcher = FileWatcher(fileURL: fileURL) { [weak self] in
            self?.scheduleCapture()
        }
        watcher.start()
        self.watcher = watcher
        log.info("watching: \(self.fileURL.path, privacy: .public)")
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        // Flush a pending debounced capture so the last edit isn't dropped.
        captureQueue.sync {
            if let work = pendingCapture, !work.isCancelled {
                work.cancel()
                pendingCapture = nil
                captureNow()
            } else {
                pendingCapture = nil
            }
        }
    }

    /// Writes a version's content back to the file. The write is then recorded
    /// as a new version through FSEvents.
    func restore(to id: Int64) throws {
        guard let content = try store.content(id: id) else { return }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // Restarts the quiet-period timer; captures once it expires without another change.
    private func scheduleCapture() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.pendingCapture?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.pendingCapture = nil
                self?.captureNow()
            }
            self.pendingCapture = work
            self.captureQueue.asyncAfter(deadline: .now() + self.debounceInterval, execute: work)
        }
    }

    private func captureNow() {
        // A missing file is not an edit: skip it rather than record a bogus
        // empty version. (Clearing an existing file IS recorded — see readContent.)
        guard let content = readContent() else { return }
        do {
            if let snapshot = try store.appendSnapshot(content: content, createdAt: Date()) {
                log.info("saved snapshot #\(snapshot.id) (\(snapshot.byteCount) bytes)")
                onSnapshot?(snapshot)
            }
        } catch {
            log.error("capture failed: \(String(describing: error), privacy: .public)")
        }
    }

    // Returns nil when the file doesn't exist (deleted/moved/renamed). An
    // existing but empty file returns "" — that's a real state (the user cleared
    // it) and must be recorded, which is exactly what this app protects.
    private func readContent() -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }
}
