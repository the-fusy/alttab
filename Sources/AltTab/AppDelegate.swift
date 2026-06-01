//
//  AppDelegate.swift
//  AltTab
//
//  Boots the app: menu bar first, then gate everything else behind Accessibility. Only once granted
//  do we start the window model and the hotkey layer (which disables native Cmd+Tab LAST).
//

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        AXUIElement.setGlobalMessagingTimeout(1)
        Task { @MainActor in Menubar.shared.install() }
        // ensureAccessibility's callback is nonisolated; hop to the main actor to start the stack.
        Permissions.ensureAccessibility {
            Task { @MainActor in
                WindowStore.shared.start()
                HotkeyManager.shared.start(session: SwitcherController.shared)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The critical restore of native Cmd+Tab is synchronous and nonisolated.
        HotkeyManager.shared.stop()
    }
}
