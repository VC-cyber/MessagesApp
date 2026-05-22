#!/usr/bin/env swift
//
//  probe-messages-ax.swift
//  Research probe: locate a specific message in Messages.app via the AX tree
//  and try to scroll it into view + highlight it.
//
//  USAGE (from repo root):
//      swift scripts/probe-messages-ax.swift "<substring to find>"
//
//  Walks down to TranscriptCollectionView, enumerates the visible message
//  rows (their `desc` attribute = "<sender>, <body>, <time>"), substring-
//  matches the argument against them, picks the best match, and:
//    1. AXScrollToVisible on the row
//    2. attempt AXSelected = true
//    3. attempt AXPress (focus the balloon)
//
//  If no row matches, attempts to scroll up via AXScrollUpByPage on the
//  transcript and re-probes, capped at 100 iterations.
//

import Cocoa
import ApplicationServices

let needle: String = {
    if CommandLine.arguments.count > 1 {
        return CommandLine.arguments[1].lowercased()
    }
    return "cactus"
}()

let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
if !AXIsProcessTrustedWithOptions(opts) {
    print("Accessibility permission missing — grant Terminal in System Settings, re-run.")
    exit(1)
}
guard let msgs = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else {
    print("Messages.app not running.")
    exit(2)
}
let app = AXUIElementCreateApplication(msgs.processIdentifier)
msgs.activate(options: [])

// MARK: - AX helpers

func axCopy<T>(_ e: AXUIElement, _ a: String) -> T? {
    var v: AnyObject?
    let err = AXUIElementCopyAttributeValue(e, a as CFString, &v)
    return err == .success ? (v as? T) : nil
}
func axChildren(_ e: AXUIElement) -> [AXUIElement] {
    var v: AnyObject?
    let err = AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
    return err == .success ? ((v as? [AXUIElement]) ?? []) : []
}
func axAttrNames(_ e: AXUIElement) -> [String] {
    var v: CFArray?
    let err = AXUIElementCopyAttributeNames(e, &v)
    return err == .success ? ((v as? [String]) ?? []) : []
}
func axActions(_ e: AXUIElement) -> [String] {
    var v: CFArray?
    let err = AXUIElementCopyActionNames(e, &v)
    return err == .success ? ((v as? [String]) ?? []) : []
}
func axIdentifier(_ e: AXUIElement) -> String? {
    axCopy(e, kAXIdentifierAttribute)
}
func axDesc(_ e: AXUIElement) -> String? {
    axCopy(e, kAXDescriptionAttribute)
}
func axRole(_ e: AXUIElement) -> String? {
    axCopy(e, kAXRoleAttribute)
}

// Depth-first search for the first descendant whose AXIdentifier matches.
func findByIdentifier(_ root: AXUIElement, _ id: String, depth: Int = 0, maxDepth: Int = 16) -> AXUIElement? {
    if axIdentifier(root) == id { return root }
    if depth >= maxDepth { return nil }
    for c in axChildren(root) {
        if let f = findByIdentifier(c, id, depth: depth + 1, maxDepth: maxDepth) {
            return f
        }
    }
    return nil
}

guard let transcript = findByIdentifier(app, "TranscriptCollectionView") else {
    print("TranscriptCollectionView not found — open a chat in Messages.app and re-run.")
    exit(3)
}

print("Found transcript. Visible rows:")
var rows = axChildren(transcript)
print("  \(rows.count) immediate children")
let firstSnapshot = rows.compactMap { axDesc($0) }.prefix(3).joined(separator: " || ")
print("  first 3 descs: \(firstSnapshot)")

func descContains(_ row: AXUIElement, _ needle: String) -> Bool {
    if let d = axDesc(row)?.lowercased(), d.contains(needle) { return true }
    return false
}

func findMatch(in root: AXUIElement, needle: String) -> AXUIElement? {
    if descContains(root, needle) { return root }
    for c in axChildren(root) {
        if let m = findMatch(in: c, needle: needle) { return m }
    }
    return nil
}

func scrollUp(_ element: AXUIElement) -> AXError {
    AXUIElementPerformAction(element, "AXScrollUpByPage" as CFString)
}
func scrollToVisible(_ element: AXUIElement) -> AXError {
    AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
}

var attempts = 0
let maxAttempts = 60
print("Searching for \"\(needle)\"...")
var lastTopSnapshot = ""
while attempts < maxAttempts {
    if let row = findMatch(in: transcript, needle: needle) {
        print("\nMATCH at attempt \(attempts):")
        print("  desc: \(axDesc(row) ?? "")")
        print("  role: \(axRole(row) ?? "?")")
        print("  attrs: \(axAttrNames(row))")
        print("  actions: \(axActions(row))")

        let err = scrollToVisible(row)
        print("AXScrollToVisible result: \(err == .success ? "OK" : "ERROR \(err.rawValue)")")

        let trueRef = kCFBooleanTrue!
        let selErr = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, trueRef)
        print("AXSelected=true result: \(selErr == .success ? "OK" : "ERROR \(selErr.rawValue)")")

        let pressErr = AXUIElementPerformAction(row, kAXPressAction as CFString)
        print("AXPress result: \(pressErr == .success ? "OK" : "ERROR \(pressErr.rawValue)")")

        if let balloon = (axChildren(row).flatMap { axChildren($0) }).first(where: { axIdentifier($0) == "CKBalloonTextView" }) {
            print("\nInner balloon found:")
            let value: String? = axCopy(balloon, kAXValueAttribute)
            print("  value: \(value?.prefix(120) ?? "<nil>")")
            let bErr = scrollToVisible(balloon)
            print("Balloon AXScrollToVisible: \(bErr == .success ? "OK" : "ERROR \(bErr.rawValue)")")
        }
        exit(0)
    }
    let r = scrollUp(transcript)
    Thread.sleep(forTimeInterval: 0.18)
    rows = axChildren(transcript)
    let topSnapshot = rows.compactMap { axDesc($0) }.prefix(2).joined(separator: " || ")
    let moved = (topSnapshot != lastTopSnapshot)
    print("  attempt \(attempts) scroll=\(r==.success ? "OK" : "ERR\(r.rawValue)") rows=\(rows.count) moved=\(moved) top: \(topSnapshot.prefix(120))")
    lastTopSnapshot = topSnapshot
    attempts += 1
}
print("Not found after \(maxAttempts) scroll-ups.")
exit(4)
