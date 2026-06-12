//
//  TextDiff.swift
//  UntitledMachine
//
//  Line-level diff of two full texts. Built on the standard library's
//  CollectionDifference (Myers), so it stays O(ND) even for tens of thousands
//  of lines, instead of a hand-rolled O(n*m) table.
//

import Foundation

enum DiffLineKind {
    case equal
    case inserted
    case deleted
}

struct DiffLine: Equatable {
    let kind: DiffLineKind
    let text: String
}

enum TextDiff {

    static func diff(from old: String, to new: String) -> [DiffLine] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        let difference = newLines.difference(from: oldLines)

        var removalsByOffset: [Int: String] = [:]
        var insertionsByOffset: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, let element, _):
                removalsByOffset[offset] = element
            case .insert(let offset, let element, _):
                insertionsByOffset[offset] = element
            }
        }

        // Walk old and new together, emitting deletions/insertions/equals in order.
        var result: [DiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if let removed = removalsByOffset[oldIndex] {
                result.append(DiffLine(kind: .deleted, text: removed))
                oldIndex += 1
            } else if let inserted = insertionsByOffset[newIndex] {
                result.append(DiffLine(kind: .inserted, text: inserted))
                newIndex += 1
            } else if oldIndex < oldLines.count && newIndex < newLines.count {
                result.append(DiffLine(kind: .equal, text: oldLines[oldIndex]))
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < oldLines.count {
                result.append(DiffLine(kind: .deleted, text: oldLines[oldIndex]))
                oldIndex += 1
            } else {
                result.append(DiffLine(kind: .inserted, text: newLines[newIndex]))
                newIndex += 1
            }
        }
        return result
    }

    // Drops the trailing empty element a final newline would otherwise produce.
    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: .newlines)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
