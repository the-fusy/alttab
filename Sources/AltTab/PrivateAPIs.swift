//
//  PrivateAPIs.swift
//  AltTab
//
//  The ENTIRE private/SPI surface of AltTab lives in this one file, on purpose: when a macOS update
//  breaks a private symbol, the blast radius is exactly here. All of these are App-Store-FORBIDDEN
//  (fine for our Developer-ID + notarized distribution) and have been stable on macOS 13/14/15 on
//  Apple Silicon.
//
//  Seven linked symbols, in three groups, plus one runtime-only Icon Services path (no new
//  link-time symbol — selectors resolved via the ObjC runtime, public fallback if they vanish):
//
//   identity / hotkey (always used):
//    1. _AXUIElementGetWindow        — AX window element → CGWindowID (our stable identity key).
//    2. CGSSetSymbolicHotKeyEnabled  — disables native Cmd+Tab so our hotkey takes over.
//
//   precise window focus (the focus path; see Focus.swift):
//    3. GetProcessForPID             — pid → ProcessSerialNumber, needed by the SLPS calls.
//    4. _SLPSSetFrontProcessWithOptions — front a process while naming a specific window id.
//    5. SLPSPostEventRecordTo        — post the WindowServer "make this window key" event record.
//
//   window Space membership (liveness; see WindowStore.applyReconcile):
//    6. _CGSDefaultConnection        — our WindowServer connection id, needed to address (7).
//    7. CGSCopySpacesForWindows      — which Spaces host given windows; distinguishes a real
//                                      other-Space window (keep) from an ordered-out ghost an
//                                      AX-dead app leaves in the WindowServer list (drop).
//
//   icon raster (WindowStore.cacheIcon):
//    ISImageDescriptor + ISIcon.CGImageForImageDescriptor: — Tahoe wraps every app.icon in a
//    Liquid Glass chiclet (HDR specular rim). We ask for the unmasked asset; if the SPI is
//    gone we just flatten app.icon to sRGB and live with the plate.
//
//  Why (3)–(5): raising a SPECIFIC window of a multi-window app is exactly what a window switcher must
//  do, and there is no robust PUBLIC API for it (NSRunningApplication.activate fronts the app's main
//  window, not the one you picked). This is the same sequence the original AltTab uses. A public-only
//  fallback is kept (commented) in Focus.swift in case a future macOS breaks the SLPS record layout.
//
//  LINKING: the CGS/SLPS symbols live in the private SkyLight.framework; Package.swift links it via
//  linkerSettings (-F /System/Library/PrivateFrameworks -framework SkyLight).
//
//  Sources (alt-tab-macos study clone):
//    _AXUIElementGetWindow            — api-wrappers/ApplicationServices.HIServices.framework.swift:4-5
//    CGSSetSymbolicHotKeyEnabled      — api-wrappers/SkyLight.framework.swift:173-174
//    _SLPSSetFrontProcessWithOptions  — api-wrappers/SkyLight.framework.swift:194-195
//    SLPSPostEventRecordTo            — api-wrappers/SkyLight.framework.swift:200-201
//    GetProcessForPID                 — api-wrappers/ApplicationServices.HIServices.framework.swift:39-40
//

import Cocoa
import ApplicationServices
import ObjectiveC

// MARK: - AX → CGWindowID (PRIVATE; ApplicationServices.HIServices)

/// Returns the CGWindowID backing an AX window element. Missing from the public AXUIElement header.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Native symbolic-hotkey toggle (PRIVATE; SkyLight)

/// Enables/disables a system symbolic hotkey (e.g. native Cmd+Tab).
/// The effect PERSISTS after the process exits, so we must restore on quit AND on crash/signal.
/// C signature is `CGError CGSSetSymbolicHotKeyEnabled(int, bool)`; Int32 matches C `int`.
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
@discardableResult
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ isEnabled: Bool) -> CGError

// MARK: - Precise window focus (PRIVATE; SkyLight + CoreServices)
//
// ProcessSerialNumber is the PUBLIC Carbon/CoreServices struct — do NOT redeclare it.

/// pid → ProcessSerialNumber. Deprecated-but-present; needed to address the SLPS calls below.
@_silgen_name("GetProcessForPID")
@discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

/// Brings a process to the front, optionally targeting a specific window id. mode 0x200 = userGenerated.
@_silgen_name("_SLPSSetFrontProcessWithOptions")
@discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: UInt32) -> CGError

/// Posts a raw WindowServer event record (the "make this window key" bytes) for the given process.
/// HIGHEST version-risk symbol (the 0xf8-byte record layout is undocumented; see Focus.makeKeyWindow).
@_silgen_name("SLPSPostEventRecordTo")
@discardableResult
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

// MARK: - Window Space membership (PRIVATE; SkyLight)

/// Our per-process connection id to the WindowServer. C signature `CGSConnectionID _CGSDefaultConnection(void)`;
/// CGSConnectionID is a C `int` ⇒ Int32. Stable across macOS 13–15 on Apple Silicon.
@_silgen_name("_CGSDefaultConnection")
func _CGSDefaultConnection() -> Int32

/// The Space ids that host the given window ids. C signature
/// `CFArrayRef CGSCopySpacesForWindows(CGSConnectionID, CGSSpaceMask, CFArrayRef windowIDs)`.
/// `mask` selects which Space category to include; 0x7 = all (current | other | user). The windowIDs
/// array bridges from `[NSNumber]`; the result bridges to `[NSNumber]` of Space ids (empty = the
/// window is on NO Space, i.e. a WindowServer ghost). Used only as a liveness tiebreaker in reconcile.
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windowIDs: CFArray) -> CFArray?

// MARK: - Unmasked app icon (PRIVATE; IconServices, runtime only)

/// Tahoe Icon Services wrap `NSRunningApplication.icon` in a Liquid Glass chiclet whose
/// specular rim is HDR (extended sRGB, values > 1.0) and blooms on the sides of the tile.
/// Ask for the same ISIcon without the mask. Returns nil if the runtime classes/selectors
/// are missing — caller then flattens `app.icon` via the public CGImage path.
enum IconServicesSPI {
    static func unmaskedCGImage(from image: NSImage,
                                pointSize: CGFloat = 128,
                                scale: CGFloat = 2) -> CGImage? {
        guard let rep = image.representations.first as NSObject?,
              let isIcon = objc_getAssociatedIcon(rep) else { return nil }
        guard let Desc = NSClassFromString("ISImageDescriptor") as? NSObject.Type,
              let allocUM = Desc.perform(NSSelectorFromString("alloc"))
        else { return nil }
        let alloc = allocUM.takeRetainedValue() as! NSObject
        let initSel = NSSelectorFromString("initWithSize:scale:")
        guard alloc.responds(to: initSel) else { return nil }
        typealias InitFn = @convention(c) (AnyObject, Selector, CGSize, CGFloat) -> Unmanaged<NSObject>
        // init consumes the +1 from alloc.
        let desc = unsafeBitCast(alloc.method(for: initSel), to: InitFn.self)(
            alloc, initSel, CGSize(width: pointSize, height: pointSize), scale
        ).takeUnretainedValue()
        let maskSel = NSSelectorFromString("setShouldApplyMask:")
        if desc.responds(to: maskSel) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(desc.method(for: maskSel), to: SetBool.self)(desc, maskSel, false)
        }
        let cgSel = NSSelectorFromString("CGImageForImageDescriptor:")
        guard isIcon.responds(to: cgSel) else { return nil }
        typealias CGFn = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<CGImage>?
        return unsafeBitCast(isIcon.method(for: cgSel), to: CGFn.self)(isIcon, cgSel, desc)?
            .takeUnretainedValue()
    }

    /// NSISIconImageRep stores the ISIcon in `_icon` and has no public getter.
    private static func objc_getAssociatedIcon(_ rep: NSObject) -> NSObject? {
        guard let ivar = class_getInstanceVariable(object_getClass(rep), "_icon") else { return nil }
        return object_getIvar(rep, ivar) as? NSObject
    }
}
