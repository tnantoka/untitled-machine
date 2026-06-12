//
//  TestSupport.swift
//  UntitledMachineTests
//

import Foundation
import Testing
@testable import UntitledMachine

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("UMTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeStore() throws -> HistoryStore {
    let dir = try makeTempDir()
    return try HistoryStore(url: dir.appendingPathComponent("history.db"))
}

/// Polls until the condition holds. FSEvents are delivered on a dedicated queue,
/// so sleeping here doesn't block their processing (no run loop needed).
func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: () throws -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    if try !condition() {
        Issue.record("condition not met within \(timeout)s", sourceLocation: sourceLocation)
    }
}
