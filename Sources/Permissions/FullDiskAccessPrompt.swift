//
//  FullDiskAccessPrompt.swift
//  BetterMessages
//
//  Helper for the "we need Full Disk Access" UX.
//
//  macOS doesn't auto-add an unsigned debug build to the Full Disk Access list
//  the way a notarized release would — the user has to drag the `.app` from
//  Finder into the FDA list themselves. So opening Settings alone is a dead
//  end: the user sees an empty list and doesn't know what to drag.
//
//  This helper does both at once:
//    1. Reveals our own `.app` in Finder (highlighted, ready to drag).
//    2. Opens System Settings → Privacy & Security → Full Disk Access.
//
//  The user then drags the highlighted .app from the Finder window into the
//  FDA list and toggles it on.
//

import AppKit
import Foundation

/// Open the Full Disk Access pane in System Settings AND reveal Better
/// Messages.app in Finder so the user can drag-and-drop it into the FDA list.
///
/// Order chosen so Finder ends up frontmost (the user's first action is the
/// drag — they need Finder on top). System Settings is opened first so it's
/// already loaded by the time the drag happens.
@MainActor
func openFullDiskAccessSettingsAndRevealApp() {
    // 1. Pre-open System Settings to the FDA pane.
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
        NSWorkspace.shared.open(url)
    }
    // 2. Reveal our running .app bundle in Finder (highlights it in the
    //    enclosing folder, ready to drag).
    let bundlePath = Bundle.main.bundlePath
    NSWorkspace.shared.selectFile(bundlePath, inFileViewerRootedAtPath: "")
}
