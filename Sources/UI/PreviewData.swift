import Foundation

/// Placeholder data types for design-agent previews.
///
/// **Lead**: reconcile with features-agent's real `Message` type during integration.
/// We keep this minimal so it's easy to map onto the real model. See
/// `plans.md` for the agreed-upon shape.
struct PreviewMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let sender: String
    let avatarInitials: String
    let body: String
    let timestamp: Date
    let chatName: String
    let isGroup: Bool
    let isFromMe: Bool

    init(
        id: UUID = UUID(),
        sender: String,
        avatarInitials: String,
        body: String,
        timestamp: Date,
        chatName: String,
        isGroup: Bool = false,
        isFromMe: Bool = false
    ) {
        self.id = id
        self.sender = sender
        self.avatarInitials = avatarInitials
        self.body = body
        self.timestamp = timestamp
        self.chatName = chatName
        self.isGroup = isGroup
        self.isFromMe = isFromMe
    }
}

enum PreviewData {
    /// A small, realistic set of search results for previews.
    static let messages: [PreviewMessage] = {
        let cal = Calendar.current
        let now = Date()
        func ago(_ unit: Calendar.Component, _ n: Int) -> Date {
            cal.date(byAdding: unit, value: -n, to: now) ?? now
        }

        return [
            PreviewMessage(
                sender: "Mom",
                avatarInitials: "M",
                body: "Don't forget grandma's birthday is on the 14th. I'll pick up flowers if you grab the cake.",
                timestamp: ago(.hour, 2),
                chatName: "Mom"
            ),
            PreviewMessage(
                sender: "Alex Chen",
                avatarInitials: "AC",
                body: "Vegas flight is booked — Thursday 6:40am. Brutal but cheap. Sending the conf to the group.",
                timestamp: ago(.day, 1),
                chatName: "Vegas planning",
                isGroup: true
            ),
            PreviewMessage(
                sender: "You",
                avatarInitials: "S",
                body: "Just landed. SFO baggage claim 5. The flight was fine actually, surprisingly smooth all the way down.",
                timestamp: ago(.day, 3),
                chatName: "Priya",
                isFromMe: true
            ),
            PreviewMessage(
                sender: "Jamie",
                avatarInitials: "J",
                body: "Did you ever read that paper I sent about retrieval-augmented generation? I want your take on the long-context experiments.",
                timestamp: ago(.day, 7),
                chatName: "Jamie"
            ),
            PreviewMessage(
                sender: "Priya",
                avatarInitials: "P",
                body: "haha okay but you have to admit the cactus place was a vibe",
                timestamp: ago(.day, 12),
                chatName: "Priya"
            ),
            PreviewMessage(
                sender: "Dad",
                avatarInitials: "D",
                body: "Car's making that noise again. Mechanic said Tuesday. Will call you after.",
                timestamp: ago(.day, 18),
                chatName: "Dad"
            ),
            PreviewMessage(
                sender: "Sam",
                avatarInitials: "S",
                body: "The Vegas group chat is unhinged today. 47 unread.",
                timestamp: ago(.day, 25),
                chatName: "Sam"
            ),
            PreviewMessage(
                sender: "Riley",
                avatarInitials: "R",
                body: "wait I never sent you the address — it's 1217 Folsom, the door code is 4421",
                timestamp: ago(.day, 40),
                chatName: "Climbing crew",
                isGroup: true
            ),
        ]
    }()

    /// A small set of sidebar selections to demo selection state.
    static let sidebarSections: [(String, [(String, String, Int?)])] = [
        ("Library", [
            ("All Messages", "tray.full", nil),
            ("People", "person.2", 247),
            ("Group Chats", "person.3", 18),
        ]),
        ("Time Range", [
            ("Last 7 days", "calendar", nil),
            ("Last 30 days", "calendar", nil),
            ("This year", "calendar", nil),
            ("All time", "infinity", nil),
        ]),
    ]
}
