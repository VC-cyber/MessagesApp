//
//  Contact.swift
//  BetterMessages
//
//  A `Contact` is a person resolved from the macOS AddressBook database,
//  potentially carrying multiple handles (one phone, one email — or three of
//  each). The `ContactResolver` owns the lookup map; this type is the value.
//

import Foundation

public struct Contact: Hashable, Sendable, Identifiable {

    /// Stable identity within this app session. We use the resolved display
    /// name as the merge key (per reference scripts: "merge by resolved name"),
    /// so this id is deterministic per name.
    public var id: String { displayName }

    /// "First Last" (or just one of them when the other is missing).
    public let displayName: String

    /// All normalized handles known to belong to this contact.
    public let handles: Set<Handle>

    public init(displayName: String, handles: Set<Handle>) {
        self.displayName = displayName
        self.handles = handles
    }
}
