//
//  EmptyStateViewController.swift
//  UntitledMachine
//
//  Shown when no file is being watched yet. Choosing a file is the one action.
//

import Cocoa

final class EmptyStateViewController: NSViewController {

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 540))

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 44, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "Keep the history of one text file")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "Untitled Machine watches a file and lets you\ngo back to any past version.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2

        let button = NSButton(title: "Choose a File…", target: self, action: #selector(choose))
        button.keyEquivalent = "\r"
        button.controlSize = .large

        let stack = NSStackView(views: [icon, title, subtitle, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(20, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    @objc private func choose() {
        FilePicker.chooseAndWatch()
    }
}
