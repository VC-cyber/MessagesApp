#!/usr/bin/env swift
//
// probe-chatkit-intent.swift
//
// Hypothesis: ChatKit.OpenMessageIntent is a hidden AppIntent in macOS 26's
// ChatKit framework (Tahoe). With `openAppWhenRun: true` and a `target: MessageEntity`
// parameter that has a `GUID` property, it can drive Messages.app to reveal a
// specific message by GUID — exactly what we need.
//
// Codex confirmed the intent exists in:
//   /System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework/Resources/Metadata.appintents/extract.actionsdata
//
// Approaches we try:
//   A) AppIntents `AppIntentPrototype.perform(targetDescriptor:, identifier:)`
//      — public-ish SPI to invoke an intent in another app by bundle ID + identifier.
//   B) AppIntents `SystemEntityQuery` to fetch a `MessageEntity` for a GUID, then
//      `AppIntents.OpenURLIntent.init(urlRepresentable:)` to materialize it as a URL.
//   C) Synthesize the URL representation directly if we can find the scheme.
//
// We use AppIntents (the macOS public framework) — which loads in our process.
// We do NOT need to load ChatKit (which is iOSSupport-only and won't load).
//

import AppIntents
import AppKit
import Foundation

if CommandLine.arguments.count < 3 {
    print("usage: probe-chatkit-intent.swift <chatGUID> <messageGUID>")
    print("  e.g. 'any;+;chat728778165720474941' 'A4C83F27-9FC6-4EFD-B2BB-B658CD0C5C7D'")
    exit(2)
}
let chatGUID = CommandLine.arguments[1]
let messageGUID = CommandLine.arguments[2]
print("chatGUID    = \(chatGUID)")
print("messageGUID = \(messageGUID)")
print()

// MARK: - Approach A: AppIntentPrototype.perform(targetDescriptor:, identifier:)
//
// AppIntents exports:
//   AppIntents.AppIntentTargetDescriptor.init(bundleIdentifier:)
//   AppIntents.AppIntentPrototype.perform(targetDescriptor:, identifier:) async throws -> Any
//
// These are Swift-only API. We construct the target descriptor for Messages.app
// (`com.apple.MobileSMS`), then call `.perform()` with the OpenMessageIntent's
// identifier `"OpenMessageIntent"`. We probably need to also pass the MessageEntity
// as a parameter — find out via runtime introspection.

print("--- Approach A: AppIntentPrototype.perform ---")

// AppIntentPrototype is a generic Swift protocol. To call its perform() extension we
// need an instance — which requires knowing the type. Most AppIntents APIs need
// concrete Swift types.
//
// BUT — we can interact through the AppIntents private bridge. Let me see if there's
// an Objective-C interface.

import ObjectiveC

let descriptorClass: AnyClass? = NSClassFromString("AppIntents.AppIntentTargetDescriptor")
print("AppIntentTargetDescriptor class = \(String(describing: descriptorClass))")

let prototypeClass: AnyClass? = NSClassFromString("AppIntents.AppIntentPrototype")
print("AppIntentPrototype class = \(String(describing: prototypeClass))")

// Try common Apple SPIs
let bridgeClass: AnyClass? = NSClassFromString("AppIntents.AppViewBridgeInternal")
print("AppViewBridgeInternal class = \(String(describing: bridgeClass))")

// AppIntents has Apple-internal entry points we might reach via objc_msgSend
let lnInteractorClass: AnyClass? = NSClassFromString("LNInteraction")
print("LNInteraction class = \(String(describing: lnInteractorClass))")

let inExecutorClass: AnyClass? = NSClassFromString("INIntentExecutionInfo")
print("INIntentExecutionInfo class = \(String(describing: inExecutorClass))")

// MARK: - Approach B: build a URL from MessageEntity URLRepresentation

print("\n--- Approach B: synthesize URLRepresentation URL ---")

// MessageEntity is URLRepresentable. The URL form (from AppIntents convention) is:
//   x-apple-appintents://<bundle-id>/<entity-type>/<entity-id>
// or
//   <app-scheme>://entity/<entity-type>/<entity-id>
//
// We'll try a battery of plausible forms.

func chatIdentifier(_ guid: String) -> String {
    let parts = guid.split(separator: ";", omittingEmptySubsequences: false)
    return parts.count == 3 ? String(parts[2]) : guid
}
let chatID = chatIdentifier(chatGUID)

let candidateURLs: [String] = [
    // x-apple-appintents convention
    "x-apple-appintents://com.apple.MobileSMS/MessageEntity/\(messageGUID)",
    "x-apple-appintents://com.apple.MobileSMS/ChatKit.MessageEntity/\(messageGUID)",
    "x-apple-appintents://com.apple.MobileSMS/OpenMessageIntent?target=\(messageGUID)",

    // appintents:// convention
    "appintents://com.apple.MobileSMS/MessageEntity/\(messageGUID)",

    // Messages-specific URL schemes
    "messages://MessageEntity/\(messageGUID)",
    "imessage://MessageEntity/\(messageGUID)",
    "sms://MessageEntity/\(messageGUID)",

    // Intent-specific
    "messages://OpenMessageIntent?target=\(messageGUID)",
    "imessage://OpenMessageIntent?target=\(messageGUID)",

    // Generic deep-link patterns
    "imessage://message/\(messageGUID)?chat=\(chatID)",
    "messages://message/\(messageGUID)?chat=\(chatID)",

    // applinks variant
    "applinks://messages.apple.com/MessageEntity/\(messageGUID)",
]

print("Testing \(candidateURLs.count) URL candidates:")
for s in candidateURLs {
    guard let url = URL(string: s) else { print("  bad URL: \(s)"); continue }
    let opened = NSWorkspace.shared.open(url)
    print("  open(\(s)) → \(opened)")
    Thread.sleep(forTimeInterval: 0.4)
}

// MARK: - Approach C: AppContext.fetchEntityURL via runtime

print("\n--- Approach C: AppContext.fetchEntityURL ---")
// AppIntents.AppContext.fetchEntityURL(entity:) takes an AnyObject and returns a URL.
// We'd need a MessageEntity instance, which we can't create (ChatKit not loadable).

// Check what we can do via the AppContext class
let appContextClass: AnyClass? = NSClassFromString("AppIntents.AppContext")
print("AppContext class = \(String(describing: appContextClass))")

// MARK: - Approach D: NSItemProvider as a transport (CoreTransferable conformance)

print("\n--- Approach D: NSItemProvider transport ---")
// MessageEntity conforms to CoreTransferable, so it might be addressable via
// an NSItemProvider for content type "com.apple.chatkit.message-entity"
// or similar. Worth trying.

print("\nDone — observe Messages.app for visible chat/message scroll behavior.")
