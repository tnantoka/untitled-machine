//
//  HistoryStoreTests.swift
//  UntitledMachineTests
//
//  The data heart. If this silently breaks, the product is dead, so cover it well.
//

import Foundation
import Testing
@testable import UntitledMachine

@MainActor
struct HistoryStoreTests {

    // MARK: - Roundtrip

    @Test func roundtrip_preservesContentExactly() throws {
        let store = try makeStore()
        let text = "line 1\n  indented\n\ttab\nUnicode 🐈‍⬛ 漢字 emoji\ntrailing newline\n"
        let snap = try #require(try store.appendSnapshot(content: text, createdAt: Date()))
        let fetched = try store.content(id: snap.id)
        #expect(fetched == text)
    }

    @Test func roundtrip_emptyContent() throws {
        let store = try makeStore()
        let snap = try #require(try store.appendSnapshot(content: "", createdAt: Date()))
        #expect(try store.content(id: snap.id) == "")
    }

    // MARK: - Dedup

    @Test func append_skipsIdenticalConsecutiveContent() throws {
        let store = try makeStore()
        let first = try store.appendSnapshot(content: "same", createdAt: Date())
        let second = try store.appendSnapshot(content: "same", createdAt: Date())
        #expect(first != nil)
        #expect(second == nil)
        #expect(try store.count() == 1)
    }

    @Test func append_savesAgainWhenContentReturnsAfterChange() throws {
        let store = try makeStore()
        try store.appendSnapshot(content: "A", createdAt: Date())
        try store.appendSnapshot(content: "B", createdAt: Date())
        // After B, the same A differs from the latest, so it's saved again.
        let again = try store.appendSnapshot(content: "A", createdAt: Date())
        #expect(again != nil)
        #expect(try store.count() == 3)
    }

    // MARK: - Fetching versions (the basis of restore)

    @Test func fetch_returnsTheExactRequestedVersion() throws {
        let store = try makeStore()
        let v1 = try #require(try store.appendSnapshot(content: "version 1", createdAt: Date()))
        let v2 = try #require(try store.appendSnapshot(content: "version 2", createdAt: Date()))
        let v3 = try #require(try store.appendSnapshot(content: "version 3", createdAt: Date()))

        #expect(try store.content(id: v1.id) == "version 1")
        #expect(try store.content(id: v2.id) == "version 2")
        #expect(try store.content(id: v3.id) == "version 3")
        #expect(try store.latest()?.content == "version 3")
    }

    @Test func previousContent_returnsTheImmediatelyOlderVersion() throws {
        let store = try makeStore()
        try store.appendSnapshot(content: "v1", createdAt: Date())
        let v2 = try #require(try store.appendSnapshot(content: "v2", createdAt: Date()))
        let v3 = try #require(try store.appendSnapshot(content: "v3", createdAt: Date()))

        #expect(try store.previousContent(before: v3.id) == "v2")
        #expect(try store.previousContent(before: v2.id) == "v1")
    }

    @Test func previousContent_isNilForTheOldestVersion() throws {
        let store = try makeStore()
        let v1 = try #require(try store.appendSnapshot(content: "only", createdAt: Date()))
        #expect(try store.previousContent(before: v1.id) == nil)
    }

    @Test func metas_areNewestFirstWithCorrectByteCount() throws {
        let store = try makeStore()
        try store.appendSnapshot(content: "a", createdAt: Date())
        try store.appendSnapshot(content: "bb", createdAt: Date())
        let metas = try store.snapshotMetas()
        #expect(metas.count == 2)
        #expect(metas.first?.byteCount == 2)   // "bb" comes first (newest)
        #expect(metas.last?.byteCount == 1)
    }

    // MARK: - Delete

    @Test func delete_removesVersion() throws {
        let store = try makeStore()
        let v1 = try #require(try store.appendSnapshot(content: "keep", createdAt: Date()))
        let v2 = try #require(try store.appendSnapshot(content: "drop", createdAt: Date()))
        try store.deleteSnapshot(id: v2.id)
        #expect(try store.count() == 1)
        #expect(try store.content(id: v2.id) == nil)
        #expect(try store.content(id: v1.id) == "keep")
    }

    // MARK: - Search (the main feature)

    @Test func search_findsContentEvenAfterItWasDeletedInLaterVersion() throws {
        let store = try makeStore()
        let v1 = try #require(try store.appendSnapshot(content: "keep this secret line", createdAt: Date()))
        try store.appendSnapshot(content: "nothing here anymore", createdAt: Date())

        // The whole point: find content that a later version removed.
        let hits = try store.search("secret")
        #expect(hits.map(\.id) == [v1.id])
    }

    @Test func search_emptyQueryReturnsNothing() throws {
        let store = try makeStore()
        try store.appendSnapshot(content: "anything", createdAt: Date())
        #expect(try store.search("").isEmpty)
        #expect(try store.search("   ").isEmpty)
    }

    @Test func search_japaneseSubstring_ftsPath() throws {
        let store = try makeStore()
        let v1 = try #require(try store.appendSnapshot(content: "今日の重要なメモ", createdAt: Date()))
        try store.appendSnapshot(content: "別の内容", createdAt: Date())
        // 3+ chars uses the FTS5 trigram path.
        #expect(try store.search("重要な").map(\.id) == [v1.id])
    }

    @Test func search_japaneseShortQuery_likePath() throws {
        let store = try makeStore()
        let v1 = try #require(try store.appendSnapshot(content: "今日の重要なメモ", createdAt: Date()))
        // 2 chars falls back to the LIKE path.
        #expect(try store.search("重要").map(\.id) == [v1.id])
    }

    @Test func search_specialCharactersDoNotCrash() throws {
        let store = try makeStore()
        try store.appendSnapshot(content: "a 100% \"quoted\" value_x", createdAt: Date())
        // The point is that these don't throw an SQL error or crash.
        #expect(throws: Never.self) {
            _ = try store.search("100%")
            _ = try store.search("\"quoted\"")
            _ = try store.search("_x")
        }
    }

    // MARK: - Empty state

    @Test func emptyStore_hasNoSnapshots() throws {
        let store = try makeStore()
        #expect(try store.count() == 0)
        #expect(try store.latest() == nil)
        #expect(try store.snapshotMetas().isEmpty)
    }
}
