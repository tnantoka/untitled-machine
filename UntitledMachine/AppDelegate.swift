//
//  AppDelegate.swift
//  UntitledMachine
//

import Cocoa

// Not @main: without a storyboard, the app delegate is wired up explicitly in
// main.swift (the storyboard used to do that).
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var windowController: NSWindowController?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        setupStatusItem()

        // Start watching regardless of any window, and keep it running.
        WatchSession.shared.resume()

        // First run (no file chosen yet): open the window so the user can pick one.
        if WatchSession.shared.fileURL == nil {
            showWindow(nil)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "clock.arrow.circlepath",
                                     accessibilityDescription: "Untitled Machine")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open History", action: #selector(showWindow(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Untitled Machine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func showWindow(_ sender: Any?) {
        if windowController == nil {
            let window = NSWindow(contentViewController: ViewController())
            window.title = "Untitled Machine"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 520))
            window.isReleasedWhenClosed = false // reused when reopened from the menu
            window.center()
            windowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(sender)
    }

    // A minimal main menu so standard shortcuts (⌘Q, ⌘C/V/X, ⌘Z) work even
    // though an accessory app doesn't display the menu bar.
    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Untitled Machine", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Untitled Machine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // The Edit menu is required, not optional: without it the standard editing
        // shortcuts (⌘C/V/X/Z/A) don't reach the text controls in this accessory app.
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
