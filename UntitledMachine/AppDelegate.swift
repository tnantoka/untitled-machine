//
//  AppDelegate.swift
//  UntitledMachine
//

import Cocoa

// Not @main: without a storyboard, the app delegate is wired up explicitly in
// main.swift (the storyboard used to do that).
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var loginMenuItem: NSMenuItem?
    private var watchingMenuItem: NSMenuItem?
    private var latestMenuItem: NSMenuItem?
    private let windowController = MainWindowController()

    private static let menuDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        setupStatusItem()

        // Start watching regardless of any window, and keep it running.
        WatchSession.shared.resume()

        // First run (no file chosen yet): open the window so the user can pick one.
        if WatchSession.shared.fileURL == nil {
            openHistory(nil)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Status item menu (the only visible menu in an accessory app)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack",
                                     accessibilityDescription: "Untitled Machine")
        let menu = NSMenu()
        menu.delegate = self

        // Info header (disabled, like Time Machine's "Latest Backup to …").
        let watching = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        watching.isEnabled = false
        menu.addItem(watching)
        watchingMenuItem = watching
        let latest = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        latest.isEnabled = false
        menu.addItem(latest)
        latestMenuItem = latest
        menu.addItem(.separator())

        menu.addItem(withTitle: "Open History", action: #selector(openHistory(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Choose File to Watch…", action: #selector(chooseFile), keyEquivalent: "")
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(login)
        loginMenuItem = login
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Untitled Machine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginMenuItem?.state = LoginItem.isEnabled ? .on : .off

        if let url = WatchSession.shared.fileURL {
            watchingMenuItem?.title = "Watching “\(url.lastPathComponent)”"
            if let date = WatchSession.shared.latestSnapshotDate {
                latestMenuItem?.title = "Latest version: \(Self.menuDateFormatter.string(from: date))"
            } else {
                latestMenuItem?.title = "No versions yet"
            }
            latestMenuItem?.isHidden = false
        } else {
            watchingMenuItem?.title = "No file being watched"
            latestMenuItem?.isHidden = true
        }
    }

    @objc private func openHistory(_ sender: Any?) {
        windowController.showWindow(sender) // promotes to .regular (Dock + menu bar)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func chooseFile() {
        FilePicker.chooseAndWatch()
        if WatchSession.shared.fileURL != nil {
            openHistory(nil)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = String(describing: error)
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // A minimal main menu so standard shortcuts work even though an accessory
    // app doesn't display the menu bar. The Edit menu is required, not optional:
    // without it ⌘C/V/X/Z/A don't reach the text controls (verified by testing).
    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Untitled Machine", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Untitled Machine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        return mainMenu
    }
}
