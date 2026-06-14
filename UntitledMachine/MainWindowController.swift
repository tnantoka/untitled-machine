//
//  MainWindowController.swift
//  UntitledMachine
//
//  Owns the window, its toolbar (search), and switches the content between the
//  empty state (no file chosen) and the history browser.
//

import Cocoa

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    private let historyVC = HistorySplitViewController()
    private let emptyVC = EmptyStateViewController()

    private lazy var toolbar: NSToolbar = {
        let t = NSToolbar(identifier: "main")
        t.delegate = self
        t.displayMode = .iconOnly
        return t
    }()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Untitled Machine"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self

        NotificationCenter.default.addObserver(
            self, selector: #selector(targetChanged), name: .watchTargetChanged, object: nil)
        updateContent()
    }

    // Show in the Dock (and the menu bar) only while the window is open, like
    // Docker Desktop: ⌘Tab works when the window is up, then back to menu-bar-only.
    override func showWindow(_ sender: Any?) {
        // Coming back from .accessory (window was closed): switch to .regular and
        // activate BEFORE ordering the window front, or it can come up unfocused
        // or not appear at all.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func targetChanged() {
        updateContent()
    }

    private func updateContent() {
        guard let window else { return }
        let fileURL = WatchSession.shared.fileURL
        let watching = fileURL != nil
        window.toolbar = watching ? toolbar : nil
        // Home-relative (~/…) reads more naturally than an absolute path.
        window.subtitle = fileURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
        window.contentViewController = watching ? historyVC : emptyVC
        window.setContentSize(NSSize(width: 860, height: 540))
    }

    // MARK: - Toolbar (search)

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == .searchItem else { return nil }
        let item = NSSearchToolbarItem(itemIdentifier: .searchItem)
        item.searchField.placeholderString = "Search all history"
        item.searchField.target = self
        item.searchField.action = #selector(searchChanged(_:))
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .searchItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .searchItem]
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        historyVC.setSearchQuery(sender.stringValue)
    }
}

extension NSToolbarItem.Identifier {
    static let searchItem = NSToolbarItem.Identifier("search")
}
