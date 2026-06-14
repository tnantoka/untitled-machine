//
//  WatchSession.swift
//  UntitledMachine
//
//  App-lifetime owner of the watching pipeline (store + coordinator), so
//  watching keeps running independently of any window. The history window is
//  just a view onto this; it reads `store` and listens for `.snapshotAdded`.
//

import Foundation
import CryptoKit

extension Notification.Name {
    static let snapshotAdded = Notification.Name("UntitledMachine.snapshotAdded")
    static let watchTargetChanged = Notification.Name("UntitledMachine.watchTargetChanged")
}

@MainActor
final class WatchSession {

    static let shared = WatchSession()

    private static let watchedFilePathKey = "watchedFilePath"

    private(set) var fileURL: URL?
    private(set) var store: HistoryStore?
    private var coordinator: HistoryCoordinator?

    private init() {}

    /// Timestamp of the most recent snapshot, for the status menu's info header.
    var latestSnapshotDate: Date? {
        guard let store else { return nil }
        return (try? store.latest())?.createdAt
    }

    /// Resumes watching the file chosen in a previous launch, if any.
    func resume() {
        guard let path = UserDefaults.standard.string(forKey: Self.watchedFilePathKey), !path.isEmpty else { return }
        try? watch(URL(fileURLWithPath: path))
    }

    /// Switches to watching `url` (stops any previous watch).
    func watch(_ url: URL) throws {
        coordinator?.stop()
        let store = try HistoryStore(url: Self.databaseURL(for: url))
        let coordinator = HistoryCoordinator(fileURL: url, store: store)
        coordinator.onSnapshot = { _ in
            Task { @MainActor in NotificationCenter.default.post(name: .snapshotAdded, object: nil) }
        }
        coordinator.start()
        self.store = store
        self.coordinator = coordinator
        self.fileURL = url
        UserDefaults.standard.set(url.path, forKey: Self.watchedFilePathKey)
        NotificationCenter.default.post(name: .watchTargetChanged, object: nil)
    }

    func restore(to id: Int64) throws {
        try coordinator?.restore(to: id)
    }

    private static func databaseURL(for fileURL: URL) throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("UntitledMachine", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One DB per watched file, so switching files keeps histories separate.
        let digest = SHA256.hash(data: Data(fileURL.standardizedFileURL.path.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return dir.appendingPathComponent("history-\(key).db")
    }
}
