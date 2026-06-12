//
//  AppDelegate.swift
//  UntitledMachine
//
//  Created by Tatsuya Tobioka on 2026/06/11.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
