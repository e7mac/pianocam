//
//  AppDelegate.swift
//  samplecamera
//
//  Created by laurent denoue on 7/1/22.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Resize the storyboard's main window to a comfortable default size
        // and center it on screen.
        if let window = NSApplication.shared.windows.first {
            window.title = "PianoCam"
            let size = NSSize(width: 1100, height: 720)
            var frame = window.frame
            frame.size = size
            window.setFrame(frame, display: true)
            window.center()
            window.minSize = NSSize(width: 800, height: 540)
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

