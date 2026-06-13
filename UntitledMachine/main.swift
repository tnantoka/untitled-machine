//
//  main.swift
//  UntitledMachine
//
//  Entry point. With no storyboard, we create the app, connect the delegate,
//  and run it ourselves. The body runs on the main actor (we're on the main
//  thread at launch), which is where AppKit and the delegate belong.
//

import Cocoa

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
