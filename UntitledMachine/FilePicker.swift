//
//  FilePicker.swift
//  UntitledMachine
//
//  Shared "choose a file and start watching it" flow, used by both the empty
//  state's button and the status-item menu.
//

import Cocoa

@MainActor
enum FilePicker {

    static func chooseAndWatch() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the text file to keep history for."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try WatchSession.shared.watch(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not open history"
            alert.informativeText = String(describing: error)
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
