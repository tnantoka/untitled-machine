//
//  LoginItem.swift
//  UntitledMachine
//
//  Thin wrapper over SMAppService for launch-at-login.
//
//  Note: registration only behaves reliably in a signed (Developer ID) build.
//  In debug builds the status may be inaccurate; verify for real on a signed
//  build by rebooting. This is why the UI surfaces the status: a failure here
//  is otherwise silent, and silent gaps defeat a history tool.
//

import ServiceManagement

enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
