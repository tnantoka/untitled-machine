//
//  TextDiffTests.swift
//  UntitledMachineTests
//

import Testing
@testable import UntitledMachine

@MainActor
struct TextDiffTests {

    @Test func identicalContent_allEqual() {
        let result = TextDiff.diff(from: "a\nb", to: "a\nb")
        #expect(result == [
            DiffLine(kind: .equal, text: "a"),
            DiffLine(kind: .equal, text: "b"),
        ])
    }

    @Test func pureInsertionAtEnd() {
        let result = TextDiff.diff(from: "a", to: "a\nb")
        #expect(result == [
            DiffLine(kind: .equal, text: "a"),
            DiffLine(kind: .inserted, text: "b"),
        ])
    }

    @Test func pureDeletion() {
        let result = TextDiff.diff(from: "a\nb", to: "a")
        #expect(result == [
            DiffLine(kind: .equal, text: "a"),
            DiffLine(kind: .deleted, text: "b"),
        ])
    }

    @Test func modifiedLine_isDeleteThenInsert() {
        let result = TextDiff.diff(from: "a\nb\nc", to: "a\nX\nc")
        #expect(result == [
            DiffLine(kind: .equal, text: "a"),
            DiffLine(kind: .deleted, text: "b"),
            DiffLine(kind: .inserted, text: "X"),
            DiffLine(kind: .equal, text: "c"),
        ])
    }

    @Test func fromEmpty_allInserted() {
        let result = TextDiff.diff(from: "", to: "a\nb")
        #expect(result == [
            DiffLine(kind: .inserted, text: "a"),
            DiffLine(kind: .inserted, text: "b"),
        ])
    }

    @Test func toEmpty_allDeleted() {
        let result = TextDiff.diff(from: "a\nb", to: "")
        #expect(result == [
            DiffLine(kind: .deleted, text: "a"),
            DiffLine(kind: .deleted, text: "b"),
        ])
    }

    @Test func trailingNewlineIsIgnoredAtLineGranularity() {
        // Line-level diff: a trailing newline alone is not a change.
        let result = TextDiff.diff(from: "a\nb\n", to: "a\nb")
        #expect(result == [
            DiffLine(kind: .equal, text: "a"),
            DiffLine(kind: .equal, text: "b"),
        ])
    }

    @Test func bothEmpty_noLines() {
        #expect(TextDiff.diff(from: "", to: "").isEmpty)
    }
}
