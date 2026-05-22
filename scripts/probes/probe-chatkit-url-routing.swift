#!/usr/bin/env swift
//
// probe-chatkit-url-routing.swift
//
// User confirmed: `x-apple-appintents://com.apple.MobileSMS/MessageEntity/<GUID>` is
// the canonical URL representation of ChatKit.MessageEntity, but `NSWorkspace.open`
// finds no LaunchServices handler for the scheme.
//
// Try multiple routing strategies:
//
//   1) NSUserActivity activityType="com.apple.Messages" with userInfo containing
//      the entity URL key. .becomeCurrent() then NSWorkspace.activate(Messages)
//      — relies on Continuity machinery picking it up.
//
//   2) CoreSpotlight CSSearchableItemActionType activity: build NSUserActivity
//      with activityType="com.apple.corespotlight.searchableitem" and
//      userInfo[CSSearchableItemActivityIdentifier] = "<x-apple-appintents URL>".
//      becomeCurrent + activate Messages.
//
//   3) Send the activity to Messages.app via the NSAppleEventManager
//      kCoreEventClass/'oURL' (kAEOpenURL) Apple Event — different code path
//      from NSWorkspace.open.
//
//   4) Try `LSOpenItem` via _LSOpenItem SPI with a hint about target bundle.
//
//   5) Try invoking AppIntents API _OpenURLIntent with our URL.
//

import AppKit
import CoreSpotlight
import Foundation

if CommandLine.arguments.count < 3 {
    print("usage: probe-chatkit-url-routing.swift <chatGUID> <messageGUID>")
    exit(2)
}
let chatGUID = CommandLine.arguments[1]
let messageGUID = CommandLine.arguments[2]
print("chatGUID    = \(chatGUID)")
print("messageGUID = \(messageGUID)")

let entityURL = URL(string: "x-apple-appintents://com.apple.MobileSMS/MessageEntity/\(messageGUID)")!
print("entityURL = \(entityURL)")
print()

// MARK: - Strategy 1: NSUserActivity with com.apple.Messages

print("--- Strategy 1: NSUserActivity com.apple.Messages + becomeCurrent ---")
let activity = NSUserActivity(activityType: "com.apple.Messages")
activity.title = "Reveal Message"
activity.userInfo = [
    "__kIMChatRegistryContinuityURLKey":         entityURL.absoluteString,
    "__kIMChatRegistryUserActivityLastMessageKey": messageGUID,
    "kCSSearchableItemActivityIdentifier":       entityURL.absoluteString,
]
activity.requiredUserInfoKeys = []
activity.isEligibleForHandoff = true
activity.isEligibleForSearch = true
activity.becomeCurrent()
print("  Made activity current. Title: \(activity.title ?? "(no title)")")

// Make Messages.app frontmost so it might pick up the current activity
if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.MobileSMS" }) {
    app.activate(options: [.activateIgnoringOtherApps])
    print("  activated com.apple.MobileSMS")
}
Thread.sleep(forTimeInterval: 1.5)
activity.invalidate()

// MARK: - Strategy 2: CoreSpotlight CSSearchableItemActionType

print("\n--- Strategy 2: CoreSpotlight activityType ---")
let csActivity = NSUserActivity(activityType: "com.apple.corespotlight.searchableitem")
csActivity.title = "Reveal Message"
csActivity.userInfo = [
    "kCSSearchableItemActivityIdentifier": entityURL.absoluteString,
    "kCSSearchQueryString":                messageGUID,
]
csActivity.requiredUserInfoKeys = ["kCSSearchableItemActivityIdentifier"]
csActivity.becomeCurrent()
print("  Made CSSearchableItem activity current")

if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.MobileSMS" }) {
    app.activate(options: [.activateIgnoringOtherApps])
    print("  activated com.apple.MobileSMS")
}
Thread.sleep(forTimeInterval: 1.5)
csActivity.invalidate()

// MARK: - Strategy 3: NSAppleEventManager kAEOpenURL

print("\n--- Strategy 3: NSAppleEventManager kAEOpenURL ---")
// Build an Apple Event:
//   eventClass = kCoreEventClass ('aevt')
//   eventID    = 'GURL' ('GURL' / kAEGetURL = 0x4755524C)
//   target     = Messages.app
//   direct param = the URL string

// 'aevt' = 0x61657674
let aevt: AEEventClass = 0x61657674  // 'aevt'
let GURL: AEEventID   = 0x4755524C  // 'GURL'
let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.MobileSMS")
let event = NSAppleEventDescriptor.appleEvent(
    withEventClass: aevt,
    eventID: GURL,
    targetDescriptor: target,
    returnID: AEReturnID(kAutoGenerateReturnID),
    transactionID: AETransactionID(kAnyTransactionID)
)
let urlDesc = NSAppleEventDescriptor(string: entityURL.absoluteString)
event.setParam(urlDesc, forKeyword: keyDirectObject)
print("  built apple event: class=aevt id=GURL target=com.apple.MobileSMS direct=\(entityURL.absoluteString)")

do {
    let reply = try event.sendEvent(options: [.defaultOptions, .canSwitchLayer], timeout: 5.0)
    print("  reply: \(reply)")
} catch {
    print("  sendEvent error: \(error)")
}
Thread.sleep(forTimeInterval: 1.0)

// MARK: - Strategy 4: NSWorkspace.openURLs(_:withApplicationAt:configuration:)

print("\n--- Strategy 4: NSWorkspace.openURLs(...withApplicationAt:Messages.app) ---")
let messagesURL = URL(fileURLWithPath: "/System/Applications/Messages.app")
let cfg = NSWorkspace.OpenConfiguration()
cfg.activates = true
cfg.requiresUniversalLinks = false

NSWorkspace.shared.open([entityURL], withApplicationAt: messagesURL, configuration: cfg) { app, err in
    print("  openURLs callback: app=\(String(describing: app)) err=\(String(describing: err))")
}
Thread.sleep(forTimeInterval: 1.5)

// MARK: - Strategy LS: LSOpenURLsWithRole (raw LaunchServices)
import CoreServices
print("\n--- Strategy LS: LSOpenURLsWithRole ---")
let lsStatus = LSOpenURLsWithRole(
    [entityURL] as NSArray as CFArray,
    .all,
    nil,
    nil,
    nil,
    nil
)
print("LSOpenURLsWithRole result: \(lsStatus)")
Thread.sleep(forTimeInterval: 1.5)

// MARK: - Strategy 5: Try multiple URL variants
print("\n--- Strategy 5: Variant URLs through NSWorkspace.openURLs ---")
let variants = [
    "x-apple-appintents://com.apple.MobileSMS/MessageEntity/\(messageGUID)",
    "x-apple-appintents://com.apple.MobileSMS/ChatKit.MessageEntity/\(messageGUID)",
    "x-apple-appintents://com.apple.MobileSMS/MessageEntity/\(messageGUID)?conversation=\(chatGUID.split(separator: ";").last ?? "")",
    "messages-appintents://MessageEntity/\(messageGUID)",
    "com.apple.MobileSMS://MessageEntity/\(messageGUID)",
]

for v in variants {
    guard let url = URL(string: v) else { continue }
    print("  trying: \(v)")
    NSWorkspace.shared.open([url], withApplicationAt: messagesURL, configuration: cfg) { app, err in
        print("    callback: app=\(String(describing: app)) err=\(String(describing: err))")
    }
    Thread.sleep(forTimeInterval: 0.5)
}

print("\nDone. Observe Messages.app to see if any approach worked.")
