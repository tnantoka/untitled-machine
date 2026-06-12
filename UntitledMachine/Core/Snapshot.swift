//
//  Snapshot.swift
//  UntitledMachine
//

import Foundation

/// A full-text snapshot of the watched file at one point in time.
/// `Sendable` so it can travel from the background capture queue to the UI.
nonisolated struct Snapshot: Identifiable, Equatable, Sendable {
    let id: Int64
    let createdAt: Date
    let content: String

    var byteCount: Int { content.utf8.count }
}

/// Lightweight metadata for list display. Deliberately omits `content` so the
/// list never loads full text, which matters for large files with many versions.
nonisolated struct SnapshotMeta: Identifiable, Equatable, Sendable {
    let id: Int64
    let createdAt: Date
    let byteCount: Int
}
