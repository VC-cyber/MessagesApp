#!/usr/bin/env swift
//
// probe-ln-perform.swift
//
// Use LinkActions (LNAction) — the Objective-C bridge that AppIntents uses
// under the hood — to construct and execute ChatKit's hidden OpenMessageIntent.
//
// Found via dyld_info on /System/Library/Frameworks/AppIntents.framework/AppIntents:
//
//   LNAction.initWithIdentifier:mangledTypeName:openAppWhenRun:parameters:
//   LNParameter.initWithIdentifier:value:
//   LNValue.initWithValue:valueType:
//   LNEntity.initWithIdentifier:properties:
//   LNEntityIdentifier.initWithTypeIdentifier:instanceIdentifier:
//   LNEntityValueType.initWithTypeName:
//   LNActionExecutor.initWithAction:connection:options:
//   LNActionExecutor.perform
//   LNConnectionAction.sendToPid:bundleIdentifier:
//
// We build an LNAction("OpenMessageIntent", "7ChatKit17OpenMessageIntentV",
// openAppWhenRun: YES, parameters: [target: MessageEntity(GUID)]) and execute it.
//

import AppKit
import Foundation
import ObjectiveC

// Unbuffered stdout for easier debugging
setbuf(stdout, nil)

// Explicitly load AppIntents — the LN* classes live here.
print("Attempting dlopen of AppIntents...")
let appIntentsHandle = dlopen("/System/Library/Frameworks/AppIntents.framework/AppIntents", RTLD_NOW)
print("AppIntents handle: \(String(describing: appIntentsHandle))")
if appIntentsHandle == nil {
    if let err = dlerror() {
        print("dlerror: \(String(cString: err))")
    }
    exit(1)
}
print("dlopen OK")

if CommandLine.arguments.count < 3 {
    print("usage: probe-ln-perform.swift <chatGUID> <messageGUID>")
    exit(2)
}
let chatGUID = CommandLine.arguments[1]
let messageGUID = CommandLine.arguments[2]
print("chatGUID    = \(chatGUID)")
print("messageGUID = \(messageGUID)")

func chatIdentifier(_ guid: String) -> String {
    let parts = guid.split(separator: ";", omittingEmptySubsequences: false)
    return parts.count == 3 ? String(parts[2]) : guid
}
let chatID = chatIdentifier(chatGUID)
print("chatID      = \(chatID)")
print()

// Use objc_msgSend directly for everything — Swift's `perform` can lose retain
// counts and class_createInstance doesn't invoke +alloc which some classes need.

// Get objc_msgSend function pointer
let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2)!, "objc_msgSend")!

// Various typealias-cast bindings for different signatures
typealias MsgSend0 = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
typealias MsgSend1 = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
typealias MsgSend2 = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Unmanaged<AnyObject>?
typealias MsgSend4 = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, Bool, AnyObject) -> Unmanaged<AnyObject>?

let msg0 = unsafeBitCast(msgSend, to: MsgSend0.self)
let msg1 = unsafeBitCast(msgSend, to: MsgSend1.self)
let msg2 = unsafeBitCast(msgSend, to: MsgSend2.self)
let msg4 = unsafeBitCast(msgSend, to: MsgSend4.self)

let SEL_alloc = NSSelectorFromString("alloc")

@inline(never)
func alloc(_ cls: AnyClass) -> AnyObject? {
    return msg0(cls, SEL_alloc)?.takeRetainedValue()
}

@inline(never)
func callInit2(_ cls: AnyClass, sel: Selector, arg1: AnyObject, arg2: AnyObject) -> AnyObject? {
    fputs("    callInit2: sel=\(NSStringFromSelector(sel))\n", stderr); fflush(stderr)
    guard let obj = alloc(cls) else { return nil }
    let result = msg2(obj, sel, arg1, arg2)
    let v = result?.takeRetainedValue()
    fputs("    callInit2 result: \(v == nil ? "nil" : "non-nil")\n", stderr); fflush(stderr)
    return v
}

@inline(never)
func callInit1(_ cls: AnyClass, sel: Selector, arg1: AnyObject) -> AnyObject? {
    fputs("    callInit1: sel=\(NSStringFromSelector(sel))\n", stderr); fflush(stderr)
    guard let obj = alloc(cls) else { return nil }
    let result = msg1(obj, sel, arg1)
    let v = result?.takeRetainedValue()
    fputs("    callInit1 result: \(v == nil ? "nil" : "non-nil")\n", stderr); fflush(stderr)
    return v
}

@inline(never)
func callInit4(_ cls: AnyClass, sel: Selector, arg1: AnyObject, arg2: AnyObject, arg3: Bool, arg4: AnyObject) -> AnyObject? {
    fputs("    callInit4: sel=\(NSStringFromSelector(sel))\n", stderr); fflush(stderr)
    guard let obj = alloc(cls) else { return nil }
    let result = msg4(obj, sel, arg1, arg2, arg3, arg4)
    let v = result?.takeRetainedValue()
    fputs("    callInit4 result: \(v == nil ? "nil" : "non-nil")\n", stderr); fflush(stderr)
    return v
}

// MARK: - Classes

guard let LNActionClass     = NSClassFromString("LNAction"),
      let LNParameterClass  = NSClassFromString("LNParameter"),
      let LNValueClass      = NSClassFromString("LNValue"),
      let LNEntityClass     = NSClassFromString("LNEntity"),
      let LNEntityIDClass   = NSClassFromString("LNEntityIdentifier"),
      let LNEntityValueType = NSClassFromString("LNEntityValueType")
else {
    print("ERROR: Missing one or more LN* classes — AppIntents may not be loaded.")
    exit(1)
}

print("LNAction:           \(LNActionClass)")
print("LNParameter:        \(LNParameterClass)")
print("LNValue:            \(LNValueClass)")
print("LNEntity:           \(LNEntityClass)")
print("LNEntityIdentifier: \(LNEntityIDClass)")
print("LNEntityValueType:  \(LNEntityValueType)")

// MARK: - Build the MessageEntity

print("\nBuilding MessageEntity...")

// LNEntityValueType.initWithTypeName:
let entityType = callInit1(LNEntityValueType, sel: NSSelectorFromString("initWithTypeName:"), arg1: "MessageEntity" as NSString)!
fputs("  entityType created\n", stderr); fflush(stderr)

// LNEntityIdentifier — try options
fputs("\n  Trying entity identifier inits...\n", stderr); fflush(stderr)
let entityID = callInit2(LNEntityIDClass, sel: NSSelectorFromString("initWithValue:typeName:"), arg1: messageGUID as NSString, arg2: "MessageEntity" as NSString)!
fputs("  entityID created\n", stderr); fflush(stderr)

// LNEntity initWithIdentifier:
let entity = callInit1(LNEntityClass, sel: NSSelectorFromString("initWithIdentifier:"), arg1: entityID)!
fputs("  entity created\n", stderr); fflush(stderr)

// LNValue.initWithValue:valueType:
let lnValue = callInit2(LNValueClass, sel: NSSelectorFromString("initWithValue:valueType:"), arg1: entity, arg2: entityType)!
fputs("  lnValue created\n", stderr); fflush(stderr)

// LNParameter.initWithIdentifier:value:
let parameter = callInit2(LNParameterClass, sel: NSSelectorFromString("initWithIdentifier:value:"), arg1: "target" as NSString, arg2: lnValue)!
fputs("  parameter created\n", stderr); fflush(stderr)

// LNAction.initWithIdentifier:mangledTypeName:openAppWhenRun:parameters:
let action = callInit4(LNActionClass,
                       sel: NSSelectorFromString("initWithIdentifier:mangledTypeName:openAppWhenRun:parameters:"),
                       arg1: "OpenMessageIntent" as NSString,
                       arg2: "7ChatKit17OpenMessageIntentV" as NSString,
                       arg3: true,
                       arg4: [parameter] as NSArray)!
fputs("  action created\n", stderr); fflush(stderr)

// Use valueForKey to extract action properties — sometimes safer than description
if let actionObj = action as? NSObject {
    if let id = actionObj.value(forKey: "identifier") as? String {
        fputs("  action.identifier = \(id)\n", stderr); fflush(stderr)
    }
    if let mtn = actionObj.value(forKey: "mangledTypeName") as? String {
        fputs("  action.mangledTypeName = \(mtn)\n", stderr); fflush(stderr)
    }
    if let openApp = actionObj.value(forKey: "openAppWhenRun") as? NSNumber {
        fputs("  action.openAppWhenRun = \(openApp.boolValue)\n", stderr); fflush(stderr)
    }
    if let url = actionObj.value(forKey: "url") as? URL {
        fputs("  action.url = \(url.absoluteString)\n", stderr); fflush(stderr)

        // Try opening the URL!
        let opened = NSWorkspace.shared.open(url)
        fputs("  Opened URL: \(opened)\n", stderr); fflush(stderr)
    } else {
        fputs("  action.url is nil\n", stderr); fflush(stderr)
    }
}

// MARK: - Approach 2: LNAppContext.performAction
print("\n--- Attempt 2: LNAppContext.performAction:options:reportingProgress:delegate:auditToken:completionHandler: ---")

if let LNAppContextClass = NSClassFromString("LNAppContext") {
    // performAction expects auditToken — we provide our own (need to get Messages.app's)
    // First, get an LNAppContext instance.
    let appCtxAlloc = (LNAppContextClass as AnyClass).alloc()
    // -init is provided
    typealias InitT = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    let initSel = NSSelectorFromString("init")
    let initImp = method_getImplementation(class_getInstanceMethod(LNAppContextClass, initSel)!)
    let initF = unsafeBitCast(initImp, to: InitT.self)
    let appCtx = initF(appCtxAlloc as AnyObject, initSel)?.takeRetainedValue()
    print("LNAppContext instance: \(String(describing: appCtx))")
}

print("\nDone — observe Messages.app behavior. Sleep 2s to let any async dispatch complete.")
Thread.sleep(forTimeInterval: 2.0)
