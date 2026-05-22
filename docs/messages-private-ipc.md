# Messages.app private-IPC research (GUID jump)

Empirical investigation of how to reach the `_automation_markAsRead:messageGUID:forChatGUID:fromMe:` (and friends) selectors inside Messages.app from our own process, so we can implement a true "jump to GUID" reveal instead of the current AX-scroll-and-keystroke fallback.

macOS 26.5 (Tahoe), Messages.app `1450.500.221.1.7`, IMCore 800.0.0. Testing date 2026-05-22.

This is a companion to `docs/messages-deep-link.md` — that file documents the URL/AX/AppleScript paths (which work, partially); this file documents the lower-level IPC paths (which we want, ideally).

## The landscape (high-level — terms first)

Messages.app on macOS 26 is **not a native AppKit application**. It's an iOS-bridged Catalyst-style app:

- Bundle ID: `com.apple.MobileSMS` (the iOS Messages app's bundle ID).
- Main binary links against `/System/iOSSupport/System/Library/PrivateFrameworks/IMCore.framework/IMCore`, `ChatKit.framework`, `IMSharedUtilities.framework` (the **iOS** copies in iOSSupport), plus `Marco.framework`, `FTServices.framework`, `IDSFoundation.framework` (native macOS PrivateFrameworks).
- Bridges through `Messages.app/Contents/PlugIns/MessagesAppKitBridge.bundle` which provides the AppKit↔UIScene glue (`CKAppKitBridge` class).
- Uses `UISceneSession` / `CKMessagesSceneDelegate` for its windows.
- We **cannot load** the iOSSupport copies of IMCore/ChatKit into our own native-macOS process: `dlopen` returns "wrong platform to load into process". (Verified — see Hypothesis 4 below.)
- But the *native macOS* `/System/Library/PrivateFrameworks/IMCore.framework` **does** dlopen successfully and has the full ObjC class graph (`IMChatRegistry`, `IMChat`, `IMMessage`, `IMDaemonController`, `IMAutomation*`, etc.) — these are the same classes Messages.app uses, just compiled for macOS instead of iOSMac.

The **daemon backing iMessage** on macOS is **`imagent`** (running as `/System/Library/PrivateFrameworks/IMCore.framework/imagent.app/Contents/MacOS/imagent`, launched from `com.apple.imagent.plist`):

```
gui/501/com.apple.imagent {
  MachServices = {
    "com.apple.aps.imagent" = true
    "com.apple.corespotlight.daemon.messages" = true
    "com.apple.imagent.cache-delete" = true
    "com.apple.imagent.desktop.auth" = true
    "com.apple.incoming-call-filter-server" = true
    "com.apple.madrid-idswake" = true
    "com.apple.madrid.lite-idswake" = true
    "com.apple.usernotifications.delegate.com.apple.iChat" = true
    "com.apple.usernotifications.delegate.com.apple.MobileSMS" = true
  }
}
```

`imagent` is the centralized state holder for everything iMessage. The Messages.app UI is just a client of imagent. IMCore (client-side library) talks to imagent over **mach service `com.apple.imagent`** via `IMDaemonController`.

`Messages.app` itself runs as PID 767 in this session and registers **no machservice of its own** — verified via `launchctl print pid/767` (the `services = {}` block is empty). Its only inbound RPC surface is therefore Apple Events / URL handling / NSUserActivity (which all go through LaunchServices → AppKit / UIKit).

## The selectors

The string `_automation_markAsRead:messageGUID:forChatGUID:fromMe:` is in the Messages.app binary. The string `_automation_markAsReadQuery:finishedWithResult:` is on `IMChatRegistry` (verified via `class_copyMethodList`). The `Automation` family in imagent is much richer:

```
imagent strings → _automation_markAsRead:messageGUID:forChatGUID:fromMe:queryID:
                  _automation_markMessagesAsRead:messageGUID:forChatGUID:fromMe:queryID:
                  _automation_receiveDictionary:options:fromID:
                  _automation_receiveDictionary:options:fromHandle:
                  _automation_sendDictionary:options:toHandles:
                  _automation_messageDeliveryControllerDidFlushCacheForRemoteURI:fromURI:guid:
```

And matching classes in the daemon:
```
IMDaemonAutomationRequestHandler
AutomationRequestHandler
"AUTOMATION Request from %@ to mark as read: %@ messageGUID %@ chatGUID: %@"
```

**Re-interpretation of these selectors** — and this is the key insight that changes the prior agent's conclusion:

- `_automation_markAsRead:…` does **not** "navigate to" or "show" a message. It marks-as-read (write side-effect on chat state). The name `automation` in IMCore refers to **MobileMe/IMS daemon automation hooks for unit tests + state-sync** — not "Messages.app's UI automation hooks". The dictionary key is `IMAutomationRequestHandler` in imagent.
- These selectors live on **`IMChatRegistry`**, which is the *client-side* library class. They are not on Messages.app's window/scene; they're on a class that runs in *any process that links IMCore* — including our own.
- That means the `_automation_*` family wouldn't help us "jump to a message in Messages.app's UI" even if we could call them, because they only operate on chat-state (mark read), not on UI navigation.

**So the original hypothesis was based on a misread.** The `_automation_` selector isn't a UI-driver; it's a state-mutator on the central daemon. It doesn't scroll Messages.app or focus a row.

## Hypotheses to test (anyway, because something must drive UI)

There has to be *some* path that drives Messages.app's UI from outside — at minimum, when you click a notification, Messages.app jumps to the correct chat. Let's identify what that path is.

Candidates:

1. **NSUserActivity continuation.** Messages.app declares:
   - `NSUserActivityTypes = ["com.apple.Messages", "com.apple.Messages.StateRestoration"]`
   - `CoreSpotlightContinuation = 1`
   - The binary contains `application:continueUserActivity:restorationHandler:`.

   This is the most promising lead: hand Messages.app an `NSUserActivity` with `activityType = "com.apple.Messages"` and some `userInfo` payload that names a chat/message, via `NSWorkspace.open` or `NSWorkspace.openURLs(_:withApplicationAt:configuration:)`. If imagent indexes chat content into CoreSpotlight, then **tapping a Spotlight result** is exactly this — we should be able to mimic it.

2. **Apple Event with `'shud'` descriptor.** The Messages.app binary handles AEs via `_handleAppleEvent:withReplyEvent:` and `processAppleEventDictionary:`. Error strings:
   - `"No 'shud' descriptor on apple event: %@"` — there IS a `'shud'` (Should-handle?) descriptor expected on certain events.
   - `"_handleAppleEvent: expected scene delegate of type 'CKMessagesSceneDelegate'. Instead got scene '%@' with delegate '%@'. Dropping Apple Event."` — the event is dispatched to a UIScene delegate, which IS the chat UI controller.

   If we can construct an `NSAppleEventDescriptor` with the right class/ID and a `'shud'` parameter, we drive the same UI path notifications use.

3. **Distributed notification with a payload.** imagent posts a fleet of these. Messages.app may listen on a name like `com.apple.imessage.openChat` with `userInfo`. Worth grepping for `addObserver:.*Notification` names in the binary.

4. **dlopen IMCore (native macOS copy) and instantiate IMChatRegistry.** Already verified: `dlopen` works, classes load, but they run in **our process** — calling `existingChatWithGUID:` gives us an `IMChat` object in our own address space, which is great for *reading* iMessage state and *sending messages on behalf of the user*, but does NOT drive Messages.app's UI.

5. **Parameterized AX attributes.** `AXUIElementCopyParameterizedAttributeNames` on a Messages.app element might expose `AXShowMessage` or similar that takes a GUID. Worth a try.

6. **URL scheme variants we haven't tried.** The `sms://` family was exhaustively probed in `docs/messages-deep-link.md`. But the Messages.app binary contains URL handling beyond `sms://`: `application:openURL:options:` is called, with options. Maybe specific `messages://` URLs with `targetContentIdentifier` or similar work.

## Hypothesis 4 verification (done — dlopen IMCore works)

```bash
# Native macOS IMCore loads fine; iOSSupport copies refuse.
dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_NOW) → OK
dlopen("/System/iOSSupport/.../IMCore", RTLD_NOW) → "wrong platform to load into process"
```

Classes recovered via `objc_copyClassList`:
- `IMChatRegistry`, `IMChat`, `IMChatHistoryController`, `IMChatItem`
- `IMMessage`, `IMMessageItem`, `IMMessageChatItem`, `IMMessageDescriptor`, `IMMessagePartGUID`, `IMMessageHistoryMessage`
- `IMHandle`, `IMHandleRegistrar`
- `IMDaemonController`, `IMDaemonConnection`, `IMDaemonListener`, `IMDaemonQuery`, `IMDaemonQueryController`
- `IMAutomation`, `IMAutomationMessageSend`, `IMAutomationBatchMessageOperations`, `IMAutomationGroupChat`
- `IMCoreAutomationHook`, `IMCoreAutomationNotifications`

Confirmed selectors that are interesting:
- `IMChatRegistry sharedInstance` (class method)
- `IMChatRegistry existingChatWithGUID:` (instance method, takes chat.guid string)
- `IMChatRegistry _cachedChatWithGUID:` (probably for already-loaded chats)
- `IMChatRegistry _cachedChatsWithMessageGUID:` (resolve message GUID → its chat[s])
- `IMChatRegistry _chat_loadPagedHistory:numberOfMessagesBefore:numberOfMessagesAfter:messageGUID:threadIdentifier:queryID:synchronous:completion:` — **history page centered on a messageGUID**
- `IMChatRegistry _clearExistingTypingIndicatorsWithMessageGUID:excludingChatWithIdentifier:` — operates on a messageGUID
- `IMChat` instances are returned by these calls
- `IMDaemonController sharedInstance` and `sendQueryWithReply:query:`

These are all *client-side* and produce read-only data / mutate daemon state. **They do not drive Messages.app's UI.** We don't pursue further as a "jump-to-GUID" mechanism — but they're useful for cross-checking what we learn from chat.db (we could resolve a message GUID to its full IMMessage object via the daemon, then use the rich metadata for a smarter AX match).

## Hypothesis 1: NSUserActivity continuation (TESTING)

[results to follow]

## Hypothesis 2: Apple Event with custom payload (TESTING)

[results to follow]

## Hypothesis 3: Distributed notification (TESTING)

[results to follow]

## Hypothesis 5: Parameterized AX attributes (TESTING)

[results to follow]

## Hypothesis 6: undocumented URL scheme params (TESTING)

[results to follow]

## Conclusion

[to be filled in]

