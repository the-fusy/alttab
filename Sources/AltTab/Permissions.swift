//
//  Permissions.swift
//  AltTab
//
//  Accessibility is the ONLY permission AltTab needs (no Screen Recording — we render icons, not
//  thumbnails). Without it the CGEventTap can't be created and no windows can be enumerated/focused.
//

import Cocoa
import ApplicationServices

enum Permissions {
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// If not yet trusted, prompt once (opens System Settings ▸ Privacy ▸ Accessibility), then poll
    /// until granted and run `onGranted` on the main thread. macOS 13+ returns stale values right
    /// after a Settings toggle, so we always re-call AXIsProcessTrusted rather than cache.
    static func ensureAccessibility(onGranted: @escaping () -> Void) {
        if AXIsProcessTrusted() { onGranted(); return }
        // Use the documented key string directly: kAXTrustedCheckOptionPrompt's Swift import type
        // (CFString! vs Unmanaged<CFString>) differs across SDKs and would break the build.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        poll(onGranted: onGranted)
    }

    private static func poll(onGranted: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if AXIsProcessTrusted() { onGranted() } else { poll(onGranted: onGranted) }
        }
    }
}
