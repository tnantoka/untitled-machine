//
//  HistoryCoordinatorTests.swift
//  UntitledMachineTests
//
//  Integration tests for the heart: FileWatcher (FSEvents) -> Coordinator ->
//  Store, exercised through a real file. FSEvents is async, so we poll.
//

import Foundation
import Testing
@testable import UntitledMachine

struct HistoryCoordinatorTests {

    /// Captures the initial content, then records a version per change.
    @Test func capturesInitialContentAndSubsequentChanges() async throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent("Untitled.txt")
        try "first".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = try HistoryStore(url: dir.appendingPathComponent("history.db"))
        let coordinator = HistoryCoordinator(fileURL: fileURL, store: store)
        defer { coordinator.stop() }

        coordinator.start()
        #expect(try store.count() == 1)
        #expect(try store.latest()?.content == "first")

        try "second".write(to: fileURL, atomically: true, encoding: .utf8)
        try await waitUntil { try store.count() == 2 }
        #expect(try store.latest()?.content == "second")
    }

    /// An identical save adds no version (dedup works through the wiring too).
    @Test func identicalSaveDoesNotCreateNewVersion() async throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent("Untitled.txt")
        try "stable".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = try HistoryStore(url: dir.appendingPathComponent("history.db"))
        let coordinator = HistoryCoordinator(fileURL: fileURL, store: store)
        defer { coordinator.stop() }

        coordinator.start()
        #expect(try store.count() == 1)

        try "stable".write(to: fileURL, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(1))
        #expect(try store.count() == 1)
    }

    /// Deleting the watched file must NOT record an empty version.
    @Test func deletingFileDoesNotRecordEmptyVersion() async throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent("Untitled.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = try HistoryStore(url: dir.appendingPathComponent("history.db"))
        let coordinator = HistoryCoordinator(fileURL: fileURL, store: store, debounceInterval: 0.2)
        defer { coordinator.stop() }

        coordinator.start()
        #expect(try store.count() == 1)

        try FileManager.default.removeItem(at: fileURL)
        try await Task.sleep(for: .seconds(1)) // past debounce + FSEvents latency
        #expect(try store.count() == 1)
    }

    /// Clearing an existing file to empty IS a real edit and must be recorded.
    @Test func clearingFileToEmptyIsRecorded() async throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent("Untitled.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = try HistoryStore(url: dir.appendingPathComponent("history.db"))
        let coordinator = HistoryCoordinator(fileURL: fileURL, store: store, debounceInterval: 0.2)
        defer { coordinator.stop() }

        coordinator.start()
        #expect(try store.count() == 1)

        try "".write(to: fileURL, atomically: true, encoding: .utf8)
        try await waitUntil { try store.count() == 2 }
        #expect(try store.latest()?.content == "")
    }

    /// Restore writes the content back to the file and records a new version.
    @Test func restoreWritesContentBackToFile() async throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent("Untitled.txt")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = try HistoryStore(url: dir.appendingPathComponent("history.db"))
        let coordinator = HistoryCoordinator(fileURL: fileURL, store: store)
        defer { coordinator.stop() }

        coordinator.start()
        let originalId = try #require(try store.latest()?.id)

        try "edited".write(to: fileURL, atomically: true, encoding: .utf8)
        try await waitUntil { try store.count() == 2 }

        try coordinator.restore(to: originalId)

        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk == "original")

        try await waitUntil { try store.latest()?.content == "original" && store.count() == 3 }
    }
}
