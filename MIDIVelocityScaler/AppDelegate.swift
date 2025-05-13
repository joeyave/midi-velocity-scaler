//
//  AppDelegate.swift
//  MIDIVelocityScaler
//
//  Created by Joseph Aveltsev on 13.05.2025.
//

import Cocoa
import CoreMIDI
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    // Ensure MIDI processing starts on app launch
    private let appState = AppState.shared
    struct Device: Hashable {
        let name: String
        let port: String
    }

    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var midiClient = MIDIClientRef()
    var selectedDevices: Set<Device> = []
    var velocityScalePercent: Int = 83

    func updateMenu() {
        print("Updating MIDI menu...")

        let hasIAC = !AppState.shared.availableOutputDevices.isEmpty

        if let button = statusItem.button {
            let symbol = hasIAC ? "pianokeys" : "exclamationmark.triangle.fill"
            let desc = hasIAC ? "MIDI Tool" : "No IAC Driver"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: desc)
        }

        let menu = NSMenu()
        if !hasIAC {
            let errorItem = NSMenuItem(title: "⚠️ IAC Driver Disabled", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(NSMenuItem.separator())
        }
        menu.addItem(
            NSMenuItem(
                title: "Open Settings",
                action: #selector(openSettings),
                keyEquivalent: "s"
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(quit),
                keyEquivalent: "q"
            )
        )
        statusItem.menu = menu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )

        // Force AppState initialization to start MIDI processing
        _ = appState

        // Defer initial menu update until after AppState finishes loading devices
        DispatchQueue.main.async {
            self.updateMenu()
        }

        MIDIClientCreateWithBlock(
            "MIDIVelocityScalerClient" as CFString,
            &midiClient
        ) { [weak self] notification in
            print("Received MIDI system notification.")
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.updateMenu()
            }
        }
    }

    @objc func openSettings() {
        if settingsWindow != nil {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = ContentView()
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 400, height: 300))
        window.title = "Settings"
        window.makeKeyAndOrderFront(nil)
        window.center()

        // Keep a reference
        self.settingsWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindow = nil
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    @objc func velocityFieldChanged(_ sender: NSTextField) {
        if let value = Int(sender.stringValue), (1...100).contains(value) {
            velocityScalePercent = value
            print("Velocity scale set to \(value)%")
        } else {
            sender.stringValue = "\(velocityScalePercent)"
        }
    }
}
