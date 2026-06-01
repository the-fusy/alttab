//
//  Menubar.swift
//  AltTab
//
//  A minimal menu-bar presence: an NSStatusItem with Launch-at-Login and Quit. No settings window.
//

import Cocoa
import ServiceManagement

@MainActor
final class Menubar {
    static let shared = Menubar()
    private var statusItem: NSStatusItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "AltTab")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let header = NSMenuItem(title: "AltTab", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit AltTab", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("AltTab: login-item toggle failed: \(error)")
        }
        // Reflect the ACTUAL post-toggle status, not an optimistic guess. On macOS 13+ register() can
        // succeed into .requiresApproval (the user must enable it under System Settings ▸ General ▸ Login
        // Items) rather than .enabled — show no checkmark then, and open that pane so the ask is visible.
        let status = SMAppService.mainApp.status
        sender.state = (status == .enabled) ? .on : .off
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
