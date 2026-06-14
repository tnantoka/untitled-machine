//
//  HistorySplitViewController.swift
//  UntitledMachine
//
//  The history browser: a native split with a content-list column (versions)
//  and a detail pane (diff / full text). It holds the browsing logic and acts
//  as the table's data source/delegate; the two child view controllers are thin
//  hosts for the views.
//

import Cocoa

final class HistorySplitViewController: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate {

    private var metas: [SnapshotMeta] = []
    private var query = ""
    private var searchTask: Task<Void, Never>?

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

    // MARK: - Setup

    override func viewDidLoad() {
        super.viewDidLoad()

        let listItem = NSSplitViewItem(contentListWithViewController: makeListViewController())
        listItem.minimumThickness = 220
        listItem.maximumThickness = 360
        addSplitViewItem(listItem)
        addSplitViewItem(NSSplitViewItem(viewController: makeDetailViewController()))

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .snapshotAdded, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .watchTargetChanged, object: nil)

        refresh(debounce: false)
    }

    private func makeListViewController() -> NSViewController {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = tableView
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("version"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self

        let vc = NSViewController()
        vc.view = scroll
        return vc
    }

    private func makeDetailViewController() -> NSViewController {
        if let textView {
            textView.isEditable = false
            textView.isRichText = true
            textView.font = Self.monoFont
            textView.textContainerInset = NSSize(width: 8, height: 8)
        }

        restoreButton.target = self
        restoreButton.action = #selector(restoreSelected)
        restoreButton.isEnabled = false
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomBar = NSStackView(views: [modeControl, spacer, restoreButton])
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 8
        bottomBar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(textScroll)
        container.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            textScroll.topAnchor.constraint(equalTo: container.topAnchor),
            textScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomBar.topAnchor.constraint(equalTo: textScroll.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let vc = NSViewController()
        vc.view = container
        return vc
    }

    // MARK: - Search (driven by the toolbar)

    func setSearchQuery(_ text: String) {
        query = text
        refresh(debounce: true)
    }

    // MARK: - Actions

    @objc private func modeChanged() {
        updateDetail()
    }

    @objc private func reload() {
        refresh(debounce: false)
    }

    @objc private func restoreSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < metas.count, let store else { return }
        let meta = metas[row]
        guard let selected = try? store.snapshot(id: meta.id) else { return }
        let current = (try? store.latest())?.content ?? ""

        let alert = NSAlert()
        alert.messageText = "Restore this version?"
        alert.informativeText = "The current file will be overwritten with the version from "
            + "\(dateFormatter.string(from: meta.createdAt)). The current state stays in history, so you can revert."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        // Preview what restoring does to the current file (current → selected).
        alert.accessoryView = Self.makeDiffPreview(from: current, to: selected.content)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try WatchSession.shared.restore(to: meta.id)
        } catch {
            presentError("Restore failed", error)
        }
    }

    private static func makeDiffPreview(from old: String, to new: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 460, height: 240)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.textStorage?.setAttributedString(attributedDiff(from: old, to: new))
        }
        return scroll
    }

    // MARK: - Data

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
        // Restore is a no-op when the selected version already equals the current
        // state (the newest snapshot), so disable it then.
        let current = (try? store.latest())?.content
        restoreButton.isEnabled = current != nil && selected.content != current

        if modeControl.selectedSegment == 0 {
            // Diff against the previous version ("what changed in this save").
            // When there's no previous (oldest version), diff the content against
            // itself so every line still gets a prefix and the view doesn't shift left.
            let base = (try? store.previousContent(before: selected.id)) ?? selected.content
            textView.textStorage?.setAttributedString(Self.attributedDiff(from: base, to: selected.content))
        } else {
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: selected.content,
                attributes: [.font: Self.monoFont, .foregroundColor: NSColor.labelColor]
            ))
        }
        highlightQuery(in: textView)
    }

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

    // MARK: - Table data source / delegate

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
