#!/usr/bin/env swift
//
// probe-user-activity.swift
//
// Hypothesis 1: NSUserActivity continuation drives Messages.app to a specific
// chat (and possibly a specific message).
//
// Background: Messages.app declares
//   NSUserActivityTypes = ["com.apple.Messages", "com.apple.Messages.StateRestoration"]
//   CoreSpotlightContinuation = 1
// And IMCore exports the constants:
//   IMChatRegistryContinuityActivityType        = "com.apple.Messages"
//   IMChatRegistryContinuityURLKey              = "__kIMChatRegistryContinuityURLKey"
//   IMChatRegistryUserActivityLastMessageKey    = "__kIMChatRegistryUserActivityLastMessageKey"
//
// Plan:
// 1. Create an NSUserActivity with activityType = "com.apple.Messages"
// 2. Set userInfo with the chat URL + message GUID
// 3. Try to make it the "current" activity (becomeCurrent) — but this binds to
//    *our* window, not Messages.app's. So that won't work directly.
// 4. The real path: hand it to Messages.app via NSWorkspace.openURL with the
//    URL key, OR use AppleEvent kAEContinueActivity, OR generate the activity
//    via UISceneSession activation request.
//
// What we WILL try here:
//   A) Construct the userInfo and call NSWorkspace.openURL on the contained URL
//      — Messages.app's application:openURL: should receive it and reach the
//      same code path that handles continuation.
//   B) Use NSWorkspace.openURLs(_:withApplicationAt:configuration:completionHandler:)
//      passing a configuration with a userActivity preset (macOS 26 API).
//   C) Try CSSearchQuery against the Messages CoreSpotlight index and observe
//      whether tapping a result fires application:continueUserActivity:.

import AppKit
import CoreSpotlight
import Foundation

// MARK: - Arguments

if CommandLine.arguments.count < 3 {
    print("usage: probe-user-activity.swift <chatGUID> <messageGUID>")
    print("  chatGUID:    chat.guid from chat.db, e.g. 'iMessage;-;+15551234567'")
    print("  messageGUID: message.guid from chat.db, e.g. 'ABC-DEF-...'")
    exit(2)
}
let chatGUID = CommandLine.arguments[1]
let messageGUID = CommandLine.arguments[2]
print("chatGUID    = \(chatGUID)")
print("messageGUID = \(messageGUID)")

// MARK: - A) Compose URL the way Messages.app's continuity code expects

// The IMChatRegistryContinuityURLKey value would be set to a URL of the form
// imessage://... or maybe a custom messages:// URL. Let's try a handful.

func chatIdentifier(fromGUID guid: String) -> String? {
    let parts = guid.split(separator: ";", omittingEmptySubsequences: false)
    if parts.count == 3 { return String(parts[2]) }
    return guid
}
guard let chatID = chatIdentifier(fromGUID: chatGUID) else {
    fatalError("can't parse chat GUID")
}

// Try a bunch of URL variants and just print which ones the open command accepts.
let urls: [String] = [
    "imessage:?chatGUID=\(chatGUID)&messageGUID=\(messageGUID)",
    "imessage://\(messageGUID)?chat=\(chatGUID)",
    "messages://message?guid=\(messageGUID)",
    "messages://\(chatID)/\(messageGUID)",
    "messages:?message=\(messageGUID)&chat=\(chatID)",
    "sms://open?groupid=\(chatID)&message=\(messageGUID)",
    "sms://open?groupid=\(chatID)&messageGUID=\(messageGUID)",
]

print("\n--- (A) URL variants we'll request OPEN on ---")
for s in urls {
    guard let u = URL(string: s) else { print("  skip (bad): \(s)"); continue }
    print("  \(u)")
}

// MARK: - B) NSUserActivity construction

// Build the activity Messages.app's continuity code would see if our DOCUMENT
// caused continuity. We can't *make* Messages.app receive it directly via the
// macOS API surface (NSUserActivity transports are: same-process becomeCurrent,
// handoff over Bluetooth, Spotlight tap). But we CAN check our build is shaped
// right by donating it to Spotlight (CSSearchableItemAttributeSet) and then
// tapping our own Spotlight item.

let activity = NSUserActivity(activityType: "com.apple.Messages")
activity.title = "Messages — chat \(chatID)"

// The two known keys IMCore exports for this activity:
let kContinuityURLKey = "__kIMChatRegistryContinuityURLKey"
let kLastMessageKey   = "__kIMChatRegistryUserActivityLastMessageKey"

// Try: URL key set to an imessage:// URL embedding the chat; lastMessage = guid
let chatURL = URL(string: "imessage://\(chatID)") ?? URL(string: "sms:?id=\(chatID)")!
activity.userInfo = [
    kContinuityURLKey: chatURL,
    kLastMessageKey:   messageGUID,
]
print("\n--- (B) NSUserActivity ---")
print("activityType = \(activity.activityType)")
print("userInfo     = \(String(describing: activity.userInfo))")

// MARK: - C) Try opening the URL via NSWorkspace (forces it through Messages.app's continuation/openURL path)

print("\n--- (C) Sending each URL via NSWorkspace.open ---")
for s in urls {
    guard let u = URL(string: s) else { continue }
    let opened = NSWorkspace.shared.open(u)
    print("  open(\(u.absoluteString)) → \(opened)")
    Thread.sleep(forTimeInterval: 0.3)
}

// MARK: - D) Try NSWorkspace.openURLs with explicit userActivity in configuration (macOS 26)

print("\n--- (D) NSWorkspace.openURLs with NSUserActivity config ---")
let cfg = NSWorkspace.OpenConfiguration()
cfg.activates = true
cfg.requiresUniversalLinks = false
cfg.allowsRunningApplicationSubstitution = true
// OpenConfiguration has no `.userActivity` slot on macOS 26 — you can't pass
// an NSUserActivity through workspace open. We'll see if Messages.app picks
// up the userInfo via launch options (it shouldn't, but worth probing).
// (OpenConfiguration in macOS 26 doesn't expose userInfo either — newer SDK.)
let messagesURL = URL(fileURLWithPath: "/System/Applications/Messages.app")
NSWorkspace.shared.openApplication(at: messagesURL, configuration: cfg) { app, err in
    print("  openApplication → app=\(String(describing: app)) err=\(String(describing: err))")
}
Thread.sleep(forTimeInterval: 1.0)

print("\nDone. Observe Messages.app window — did it scroll to or focus the specific message?")
print("If yes, capture the URL/key combination that worked.")
