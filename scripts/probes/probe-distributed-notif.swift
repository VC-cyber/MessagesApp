#!/usr/bin/env swift
//
// probe-distributed-notif.swift
//
// Hypothesis 3: Some distributed notification with chat/message GUID payload
// triggers Messages.app to navigate to that message.
//
// We try a battery of plausible names and a userInfo payload with multiple
// chat/message key variants. Observe Messages.app for visible scroll behavior.

import Foundation

if CommandLine.arguments.count < 3 {
    print("usage: probe-distributed-notif.swift <chatGUID> <messageGUID>")
    exit(2)
}
let chatGUID = CommandLine.arguments[1]
let messageGUID = CommandLine.arguments[2]
print("chatGUID    = \(chatGUID)")
print("messageGUID = \(messageGUID)")

// chatID without prefix
let chatID: String = {
    let parts = chatGUID.split(separator: ";", omittingEmptySubsequences: false)
    return parts.count == 3 ? String(parts[2]) : chatGUID
}()

let candidateNames = [
    // ChatKit notifications — based on exports
    "CKEmphasizeBalloonAtIndexPathNotification",
    "CKConversationListSelectionDidChangeNotification",
    "CKConversationListChangedNotification",
    // Plausible "open chat" / "reveal message" notifications
    "com.apple.imessage.openChat",
    "com.apple.imessage.revealMessage",
    "com.apple.messages.openChat",
    "com.apple.messages.revealMessage",
    "com.apple.imagent.openChat",
    "IMOpenChatNotification",
    "IMRevealMessageNotification",
    "IMShowMessageNotification",
    // Some IMCore notifications worth trying
    "IMChatMessageDidChangeNotification",
    "IMChatItemsDidChangeNotification",
]

// Build a userInfo with every plausible key variant
let userInfo: [String: Any] = [
    "chat_guid":     chatGUID,
    "chatGUID":      chatGUID,
    "ChatGUID":      chatGUID,
    "chat":          chatGUID,
    "chatID":        chatID,
    "chat_id":       chatID,
    "groupid":       chatID,
    "messageGUID":   messageGUID,
    "messageId":     messageGUID,
    "message_guid":  messageGUID,
    "message_id":    messageGUID,
    "MessageGUID":   messageGUID,
    "msg_guid":      messageGUID,
    "__kIMChatRegistryUserActivityLastMessageKey": messageGUID,
    "__kIMChatRegistryContinuityURLKey":           "imessage://\(chatID)",
]

let dnc = DistributedNotificationCenter.default()
let lnc = NotificationCenter.default

for name in candidateNames {
    print("\n--- posting: \(name) ---")
    // Distributed (cross-process)
    dnc.postNotificationName(Notification.Name(name), object: nil, userInfo: userInfo, deliverImmediately: true)
    // Local (might be intercepted by something running in our address space)
    lnc.post(name: Notification.Name(name), object: nil, userInfo: userInfo)
    Thread.sleep(forTimeInterval: 0.5)  // settle
    print("  posted")
}

print("\nObserve Messages.app — did any notification cause visible scroll/highlight?")
