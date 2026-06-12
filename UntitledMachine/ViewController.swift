//
//  ViewController.swift
//  UntitledMachine
//

import Cocoa
import CryptoKit
import os

final class ViewController: NSViewController {

    private static let watchedFilePathKey = "watchedFilePath"
    private let log = Logger(subsystem: "com.tnantoka.UntitledMachine", category: "ui")

    private var store: HistoryStore?
    private var coordinator: HistoryCoordinator?
    private var metas: [SnapshotMeta] = []
    private var query = ""

    private let pathLabel = NSTextField(labelWithString: "No file selected")
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let textScroll = NSTextView.scrollableTextView()
    private let restoreButton = NSButton(title: "Restore This Version", target: nil, action: nil)
    private let modeControl = NSSegmentedControl(labels: ["Diff", "Full"], trackingMode: .selectOne, target: nil, action: nil)

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm:ss"
        return f
    }()

    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private var textView: NSTextView? { textScroll.documentView as? NSTextView }

    // MARK: - Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 520))

        let chooseButton = NSButton(title: "Choose File…", target: self, action: #selector(chooseFile))
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.placeholderString = "Search all history"
        searchField.setContentHuggingPriority(.required, for: .horizontal)
        searchField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let topBar = NSStackView(views: [chooseButton, pathLabel, searchField])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.documentView = tableView
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("version"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .inset

        if let textView {
            textView.isEditable = false
            textView.isRichText = true
            textView.font = Self.monoFont
            textView.textContainerInset = NSSize(width: 8, height: 8)
        }

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(listScroll)
        split.addArrangedSubview(textScroll)
        // Keep the list a fixed-ish width; let the detail pane absorb resizing.
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        restoreButton.target = self
        restoreButton.action = #selector(restoreSelected)
        restoreButton.isEnabled = false
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomBar = NSStackView(views: [modeControl, bottomSpacer, restoreButton])
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 8
        bottomBar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(topBar)
        root.addSubview(split)
        root.addSubview(bottomBar)

        let preferredListWidth = listScroll.widthAnchor.constraint(equalToConstant: 280)
        preferredListWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            split.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            bottomBar.topAnchor.constraint(equalTo: split.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            listScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            preferredListWidth,
        ])

        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Resume watching the file chosen in a previous launch.
        if let path = UserDefaults.standard.string(forKey: Self.watchedFilePathKey), !path.isEmpty {
            startWatching(URL(fileURLWithPath: path))
        }
    }

    // MARK: - Actions

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the text file to keep history for."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Self.watchedFilePathKey)
        startWatching(url)
    }

    @objc private func modeChanged() {
        updateDetail()
    }

    @objc private func filterChanged() {
        query = searchField.stringValue
        reloadVersions()
    }

    @objc private func restoreSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < metas.count, let coordinator else { return }
        do {
            try coordinator.restore(to: metas[row].id)
        } catch {
            presentError("Restore failed", error)
        }
    }

    // MARK: - Watching

    private func startWatching(_ fileURL: URL) {
        coordinator?.stop()
        do {
            let store = try HistoryStore(url: databaseURL(forWatchedFile: fileURL))
            let coordinator = HistoryCoordinator(fileURL: fileURL, store: store)
            coordinator.onSnapshot = { [weak self] _ in
                // Fired on the watcher's background queue; hop to the main actor.
                Task { @MainActor in self?.reloadVersions() }
            }
            coordinator.start()
            self.store = store
            self.coordinator = coordinator
            pathLabel.stringValue = fileURL.path
            reloadVersions()
        } catch {
            presentError("Could not open history", error)
        }
    }

    private func reloadVersions() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            metas = (try? store?.snapshotMetas()) ?? []
        } else {
            metas = (try? store?.search(trimmed)) ?? []
        }
        tableView.reloadData()
        // Select the newest version so the detail pane shows something right away.
        if tableView.selectedRow < 0, !metas.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateDetail()
    }

    // MARK: - Detail (diff / full text)

    private func updateDetail() {
        guard let textView else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < metas.count, let store,
              let selected = try? store.snapshot(id: metas[row].id) else {
            textView.string = ""
            restoreButton.isEnabled = false
            return
        }
        restoreButton.isEnabled = true

        let showDiff = modeControl.selectedSegment == 0
        // Ask the store for the true predecessor by id, so diff stays correct
        // even when the list is filtered by a search.
        let olderContent = (try? store.previousContent(before: selected.id)) ?? nil

        if showDiff, let olderContent {
            textView.textStorage?.setAttributedString(Self.attributedDiff(from: olderContent, to: selected.content))
        } else {
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: selected.content,
                attributes: [.font: Self.monoFont, .foregroundColor: NSColor.labelColor]
            ))
        }
        highlightQuery(in: textView)
    }

    // Highlights occurrences of the current search text in the detail pane.
    private func highlightQuery(in textView: NSTextView) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let storage = textView.textStorage else { return }
        let full = storage.string as NSString
        var searchRange = NSRange(location: 0, length: full.length)
        while searchRange.location < full.length {
            let found = full.range(of: trimmed, options: .caseInsensitive, range: searchRange)
            if found.location == NSNotFound { break }
            storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4), range: found)
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: full.length - next)
        }
    }

    private static func attributedDiff(from old: String, to new: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for line in TextDiff.diff(from: old, to: new) {
            let prefix: String
            let color: NSColor
            switch line.kind {
            case .equal:    prefix = "  "; color = .labelColor
            case .inserted: prefix = "+ "; color = .systemGreen
            case .deleted:  prefix = "- "; color = .systemRed
            }
            result.append(NSAttributedString(
                string: prefix + line.text + "\n",
                attributes: [.font: monoFont, .foregroundColor: color]
            ))
        }
        return result
    }

    private func databaseURL(forWatchedFile fileURL: URL) throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("UntitledMachine", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One DB per watched file, so switching files keeps histories separate.
        let digest = SHA256.hash(data: Data(fileURL.standardizedFileURL.path.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return dir.appendingPathComponent("history-\(key).db")
    }

    private func presentError(_ title: String, _ error: Error) {
        log.error("\(title, privacy: .public): \(String(describing: error), privacy: .public)")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Table data source / delegate

extension ViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        metas.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            return c
        }()
        let meta = metas[row]
        cell.textField?.stringValue = "\(dateFormatter.string(from: meta.createdAt))  ·  \(meta.byteCount) B"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }
}
