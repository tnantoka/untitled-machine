//
//  FileWatcher.swift
//  UntitledMachine
//
//  Watches a single file with FSEvents.
//
//  We watch the parent directory, not the file itself: many editors save by
//  writing a temp file and renaming it into place, which changes the inode and
//  would be missed by watching the file directly. We then notify only when an
//  event path matches the target file.
//

import Foundation
import CoreServices

nonisolated final class FileWatcher {

    private let fileURL: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    // A dedicated serial queue, so delivery never depends on the main run loop
    // being free. Keeps large files off the main thread and makes tests reliable.
    private let queue = DispatchQueue(label: "com.tnantoka.UntitledMachine.FileWatcher")

    /// `onChange` is called on `queue` when the target file changes.
    init(fileURL: URL, onChange: @escaping () -> Void) {
        self.fileURL = fileURL.standardizedFileURL
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }

        let dir = fileURL.deletingLastPathComponent().path
        let paths = [dir] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.handle(paths: paths)
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, // latency, in seconds: coalesces rapid saves
            flags
        ) else {
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(paths: [String]) {
        // Resolve symlinks so e.g. /tmp vs /private/tmp still matches.
        let target = fileURL.resolvingSymlinksInPath().path
        let matched = paths.contains { path in
            path == fileURL.path
                || URL(fileURLWithPath: path).resolvingSymlinksInPath().path == target
        }
        if matched {
            onChange()
        }
    }
}
