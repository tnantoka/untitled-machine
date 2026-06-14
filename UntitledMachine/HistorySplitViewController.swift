//
//  HistorySplitViewController.swift
//  UntitledMachine
//
//  The history browser: a native split with a content-list column (versions
//  grouped by day) and a detail pane (diff / full text). It holds the browsing
//  logic and acts as the table's data source/delegate; the two child view
//  controllers are thin hosts for the views.
//

import Cocoa

final class HistorySplitViewController: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate {

    // A row is either a day header or a version. Headers come from grouping the
    // metas by calendar day; they aren't selectable.
    private enum Row {
        case header(String)
        case version(SnapshotMeta, subtitle: String)
    }

    private var metas: [SnapshotMeta] = []
    private var rows: [Row] = []
    private var query = ""
    private var searchTask: Task<Void, Never>?

    private let tableView = VersionTableView()
    private let textScroll = NSTextView.scrollableTextView()
    private let restoreButton = NSButton(title: "Restore This Version", target: nil, action: nil)
    private let removeButton = NSButton()
    private let modeControl = NSSegmentedControl(labels: ["Diff", "Full"], trackingMode: .selectOne, target: nil, action: nil)

    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let footerHeight: CGFloat = 38

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static let headerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
    private let dialogDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

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
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("version"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onDeleteKey = { [weak self] in self?.deleteSelected() }

        // Right-click → Delete (the standard, discoverable way to delete a row).
        let contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "Delete Version", action: #selector(deleteFromContextMenu), keyEquivalent: "")
        tableView.menu = contextMenu

        removeButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete version")
        removeButton.bezelStyle = .texturedRounded
        removeButton.imagePosition = .imageOnly
        removeButton.toolTip = "Delete the selected version permanently"
        removeButton.target = self
        removeButton.action = #selector(deleteSelected)
        removeButton.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [removeButton, spacer])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: Self.footerHeight).isActive = true

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let vc = NSViewController()
        vc.view = container
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
        bottomBar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.heightAnchor.constraint(equalToConstant: Self.footerHeight).isActive = true
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
        guard let store, let meta = selectedMeta(),
              let selected = try? store.snapshot(id: meta.id) else { return }
        let current = (try? store.latest())?.content ?? ""

        let alert = NSAlert()
        alert.messageText = "Restore this version?"
        alert.informativeText = "The current file will be overwritten with the version from "
            + "\(dialogDateFormatter.string(from: meta.createdAt)). The current state stays in history, so you can revert."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = Self.makeDiffPreview(from: current, to: selected.content)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try WatchSession.shared.restore(to: meta.id)
        } catch {
            presentError("Restore failed", error)
        }
    }

    @objc private func deleteFromContextMenu() {
        let row = tableView.clickedRow
        if row >= 0, row < rows.count, case .version = rows[row] {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        deleteSelected()
    }

    @objc private func deleteSelected() {
        guard let store, let meta = selectedMeta() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this version?"
        alert.informativeText = "This permanently removes the version from "
            + "\(dialogDateFormatter.string(from: meta.createdAt)). This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.deleteSnapshot(id: meta.id)
            refresh(debounce: false)
        } catch {
            presentError("Delete failed", error)
        }
    }

    // MARK: - Data

    private func refresh(debounce: Bool) {
        guard let store else {
            setMetas([])
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
            self?.setMetas(result)
        }
    }

    private func setMetas(_ newMetas: [SnapshotMeta]) {
        metas = newMetas
        rows = Self.buildRows(from: newMetas)
        tableView.reloadData()
        // Select the newest version (first non-header row) so the detail shows.
        if tableView.selectedRow < 0,
           let firstVersion = rows.firstIndex(where: { if case .version = $0 { return true } else { return false } }) {
            tableView.selectRowIndexes(IndexSet(integer: firstVersion), byExtendingSelection: false)
        }
        updateDetail()
    }

    private static func buildRows(from metas: [SnapshotMeta]) -> [Row] {
        var result: [Row] = []
        var lastHeader: String?
        for (i, meta) in metas.enumerated() {
            let header = dayHeader(for: meta.createdAt)
            if header != lastHeader {
                result.append(.header(header))
                lastHeader = header
            }
            // metas are newest-first, so the next one is the older version.
            let previous = (i + 1 < metas.count) ? metas[i + 1] : nil
            result.append(.version(meta, subtitle: changeSubtitle(current: meta, previous: previous)))
        }
        return result
    }

    private static func dayHeader(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return headerDateFormatter.string(from: date)
    }

    private static func changeSubtitle(current: SnapshotMeta, previous: SnapshotMeta?) -> String {
        guard let previous else { return "Initial version" }
        let delta = current.byteCount - previous.byteCount
        if delta == 0 { return "Edited" }
        let sign = delta > 0 ? "+" : "−"
        let size = ByteCountFormatter.string(fromByteCount: Int64(abs(delta)), countStyle: .file)
        return "\(sign)\(size)"
    }

    private func selectedMeta() -> SnapshotMeta? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case let .version(meta, _) = rows[row] else { return nil }
        return meta
    }

    // MARK: - Detail (diff / full text)

    private func updateDetail() {
        guard let textView else { return }
        guard let store, let meta = selectedMeta(),
              let selected = try? store.snapshot(id: meta.id) else {
            textView.string = ""
            restoreButton.isEnabled = false
            removeButton.isEnabled = false
            return
        }
        removeButton.isEnabled = true // any version can be deleted
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

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 22 }
        return 40
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let id = NSUserInterfaceItemIdentifier("header")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.makeHeaderCell(id)
            cell.textField?.stringValue = title
            return cell
        case .version(let meta, let subtitle):
            let id = NSUserInterfaceItemIdentifier("version")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? VersionCellView) ?? VersionCellView(identifier: id)
            cell.titleField.stringValue = Self.timeFormatter.string(from: meta.createdAt)
            cell.subtitleField.stringValue = subtitle
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }

    private static func makeHeaderCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 11, weight: .semibold)
        tf.textColor = .secondaryLabelColor
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
        ])
        cell.identifier = id
        return cell
    }
}

// Table that deletes the selected version on ⌫ / forward-delete.
private final class VersionTableView: NSTableView {
    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117] // delete, forward delete
        if deleteKeys.contains(event.keyCode), selectedRow >= 0 {
            onDeleteKey?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// Two-line version row: time on top, change magnitude below.
private final class VersionCellView: NSTableCellView {
    let titleField = NSTextField(labelWithString: "")
    let subtitleField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        titleField.font = .systemFont(ofSize: 13)
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleField, subtitleField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
