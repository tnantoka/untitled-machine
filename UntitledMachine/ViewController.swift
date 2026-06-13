//
//  ViewController.swift
//  UntitledMachine
//
//  A view onto WatchSession.shared. It owns no watching state; it queries the
//  session's store and refreshes when notified of new snapshots.
//

import Cocoa

final class ViewController: NSViewController {

    private var metas: [SnapshotMeta] = []
    private var query = ""
    private var searchTask: Task<Void, Never>?

    private let pathLabel = NSTextField(labelWithString: "No file selected")
    private let searchField = NSSearchField()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
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
    private var store: HistoryStore? { WatchSession.shared.store }

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
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)
        let topBar = NSStackView(views: [chooseButton, pathLabel, searchField, launchAtLoginCheckbox])
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(snapshotDidArrive), name: .snapshotAdded, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(watchTargetDidChange), name: .watchTargetChanged, object: nil)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reflectTarget()
        syncLoginCheckbox()
        refresh(debounce: false)
    }

    // MARK: - Notifications

    @objc private func snapshotDidArrive() { refresh(debounce: false) }

    @objc private func watchTargetDidChange() {
        reflectTarget()
        refresh(debounce: false)
    }

    // MARK: - Actions

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the text file to keep history for."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try WatchSession.shared.watch(url)
        } catch {
            presentError("Could not open history", error)
        }
    }

    @objc private func modeChanged() {
        updateDetail()
    }

    @objc private func filterChanged() {
        query = searchField.stringValue
        refresh(debounce: true)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(launchAtLoginCheckbox.state == .on)
        } catch {
            presentError("Could not change the login item", error)
        }
        syncLoginCheckbox() // reflect the real status, even if the change failed
    }

    @objc private func restoreSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < metas.count else { return }
        do {
            try WatchSession.shared.restore(to: metas[row].id)
        } catch {
            presentError("Restore failed", error)
        }
    }

    // MARK: - State reflection

    private func reflectTarget() {
        pathLabel.stringValue = WatchSession.shared.fileURL?.path ?? "No file selected"
    }

    private func syncLoginCheckbox() {
        launchAtLoginCheckbox.state = LoginItem.isEnabled ? .on : .off
    }

    // Reloads the version list. The query runs off the main thread so a heavy
    // search (e.g. a short query that falls back to a full LIKE scan over a large
    // history) never freezes the UI. `debounce` waits out rapid typing first.
    private func refresh(debounce: Bool) {
        guard let store else {
            metas = []
            tableView.reloadData()
            updateDetail()
            return
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            let result = await Task.detached {
                q.isEmpty ? ((try? store.snapshotMetas()) ?? [])
                          : ((try? store.search(q)) ?? [])
            }.value
            if Task.isCancelled { return }
            guard let self else { return }
            self.metas = result
            self.tableView.reloadData()
            if self.tableView.selectedRow < 0, !self.metas.isEmpty {
                self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            self.updateDetail()
        }
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

    private func presentError(_ title: String, _ error: Error) {
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
