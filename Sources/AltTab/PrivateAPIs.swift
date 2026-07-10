//
//  PrivateAPIs.swift
//  AltTab
//
//  The ENTIRE private/SPI surface of AltTab lives in this one file, on purpose: when a macOS update
//  breaks a private symbol, the blast radius is exactly here. All of these are App-Store-FORBIDDEN
//  (fine for our Developer-ID + notarized distribution) and have been stable on macOS 13/14/15 on
//  Apple Silicon.
//
//  Seven symbols, in three groups:
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
