//
//  HelpSheet.swift
//  BetterMessages
//
//  A glanceable filter-syntax cheatsheet shown over the spotlight panel.
//
//  Why
//  ---
//  The empty state surfaces the *most useful* filter buttons; the rotating
//  placeholder hints at *some* filter syntax. But the full grammar is
//  rich — case modifiers, co-occurrence, multi-word quotes, `to:` vs
//  `from:`, the named reaction kinds — and a dense reference is the only
//  way to expose the long tail without bloating the always-visible UI.
//
//  Trigger
//  -------
//  - A small `?` button in the spotlight panel's footer.
//  - Or `⌘/` from anywhere in the panel (keyboard convention for "open
//    help"; matches Slack, Linear, and Apple's own first-party apps).
//
//  Visual
//  ------
//  Edge-to-edge overlay on the panel (not a separate window). Backed by
//  `.regularMaterial` — overlays are exactly the case where Apple's HIG
//  *does* permit material backing on a content layer because the overlay
//  IS chrome with respect to the content underneath. Escape dismisses.
//
//  Each token entry has a tinted icon (matching its FilterCategory), the
//  literal token, a one-line description, and an example. Clicking the
//  example inserts it into the search field, runs the search, and closes
//  the sheet — turning the cheatsheet into a launchpad as well as a
//  reference.
//

import SwiftUI

/// One entry in the help sheet. Owns its category, prefix, description,
/// and a click-to-run example.
struct HelpEntry: Identifiable, Hashable {
    let id: String
    let token: String
    let description: String
    let example: String
    let category: FilterCategory

    init(token: String, description: String, example: String, category: FilterCategory) {
        self.id = token
        self.token = token
        self.description = description
        self.example = example
        self.category = category
    }
}

/// A section of the help sheet — title + entries.
struct HelpSection: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let entries: [HelpEntry]
}

extension HelpSection {
    /// The canonical reference list. Mirrors `MessageSearch.parseQuery`
    /// and `Sources/Search/QueryAutocomplete.swift::TokenPrefix`. When a
    /// new prefix lands there, add it here too.
    static let allSections: [HelpSection] = [
        HelpSection(
            id: "people",
            title: "People",
            icon: "person.crop.circle",
            entries: [
                .init(
                    token: "from:NAME",
                    description: "Messages sent by NAME (contact name or raw handle).",
                    example: "from:Mom",
                    category: .person
                ),
                .init(
                    token: "to:NAME",
                    description: "Messages you sent to NAME (1:1 or group with NAME).",
                    example: "to:Alex",
                    category: .person
                ),
            ]
        ),
        HelpSection(
            id: "chat",
            title: "Chat",
            icon: "bubble.left.and.bubble.right",
            entries: [
                .init(
                    token: "chat:NAME",
                    description: "Scope to chats whose name contains NAME.",
                    example: "chat:family",
                    category: .chat
                ),
                .init(
                    token: "in:NAME",
                    description: "Alias for chat: — scope to a named chat.",
                    example: "in:Vegas",
                    category: .chat
                ),
            ]
        ),
        HelpSection(
            id: "date",
            title: "Date",
            icon: "calendar",
            entries: [
                .init(
                    token: "last:7d",
                    description: "Relative window. Supports d, w, mo, y (e.g. last:24h, last:3mo).",
                    example: "last:7d",
                    category: .dateRange
                ),
                .init(
                    token: "after:DATE",
                    description: "Messages on or after DATE. ISO (YYYY-MM-DD), MM/DD/YYYY, or natural (yesterday, may 8 2026).",
                    example: "after:2025-01-01",
                    category: .dateRange
                ),
                .init(
                    token: "before:DATE",
                    description: "Messages before DATE. Same formats as after:.",
                    example: "before:yesterday",
                    category: .dateRange
                ),
                .init(
                    token: "on:DATE",
                    description: "Messages on a single day. Sugar for after: + before:.",
                    example: "on:2025-12-25",
                    category: .dateRange
                ),
            ]
        ),
        HelpSection(
            id: "reactions",
            title: "Reactions",
            icon: "heart.fill",
            entries: [
                .init(
                    token: "reactions:>=N",
                    description: "Messages with at least N reactions. Also <=, >, <, = N.",
                    example: "reactions:>=3",
                    category: .reaction
                ),
                .init(
                    token: "reactions:any",
                    description: "Messages with at least one reaction (alias for >=1).",
                    example: "reactions:any",
                    category: .reaction
                ),
                .init(
                    token: "reactions:KIND",
                    description: "Filter by reaction kind: love, like, laugh, emphasize, question, dislike.",
                    example: "reactions:love",
                    category: .reaction
                ),
            ]
        ),
        HelpSection(
            id: "type",
            title: "Content type",
            icon: "doc.richtext",
            entries: [
                .init(
                    token: "type:image",
                    description: "Image attachments (photos, screenshots).",
                    example: "type:image",
                    category: .type
                ),
                .init(
                    token: "type:video",
                    description: "Video attachments.",
                    example: "type:video",
                    category: .type
                ),
                .init(
                    token: "type:link",
                    description: "Messages with URL link previews.",
                    example: "type:link",
                    category: .type
                ),
                .init(
                    token: "type:audio",
                    description: "Voice notes and audio attachments.",
                    example: "type:audio",
                    category: .type
                ),
                .init(
                    token: "type:sticker",
                    description: "Peel-and-stick stickers.",
                    example: "type:sticker",
                    category: .type
                ),
                .init(
                    token: "type:file",
                    description: "PDFs, documents, and other files.",
                    example: "type:file",
                    category: .type
                ),
                .init(
                    token: "type:attachment",
                    description: "Any non-text content. Multiple type: tokens OR together.",
                    example: "type:attachment",
                    category: .type
                ),
                .init(
                    token: "type:text",
                    description: "Plain text only — no attachments.",
                    example: "type:text",
                    category: .type
                ),
            ]
        ),
        HelpSection(
            id: "free-text",
            title: "Text matching",
            icon: "text.magnifyingglass",
            entries: [
                .init(
                    token: "WORD",
                    description: "Substring match, case-insensitive by default.",
                    example: "cactus",
                    category: .freeText
                ),
                .init(
                    token: "A+B",
                    description: "Co-occurrence — both terms must appear in the same message.",
                    example: "vacation+flight",
                    category: .freeText
                ),
                .init(
                    token: "\"two words\"",
                    description: "Quote multi-word values for any filter, including free text.",
                    example: "chat:\"Amme Satyajit\"",
                    category: .freeText
                ),
                .init(
                    token: "case:sensitive",
                    description: "Make the phrase match case-sensitive. Aliases: case:cs, case:on.",
                    example: "iPhone case:sensitive",
                    category: .freeText
                ),
            ]
        ),
    ]
}

struct HelpSheet: View {
    let onClose: () -> Void
    let onInsert: (String) -> Void

    @State private var hoveringClose = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            sections
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        // Escape dismisses — matches the panel's own dismiss-on-escape and
        // keeps the help sheet from "trapping" the keyboard.
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Search syntax")
                .font(.headline)
            Spacer()
            Text("⌘/ to toggle  ·  esc to close")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(
                        Circle().fill(
                            hoveringClose
                                ? Color.primary.opacity(0.12)
                                : Color.primary.opacity(0.06)
                        )
                    )
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .help("Close (esc)")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    private var sections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                ForEach(HelpSection.allSections) { section in
                    sectionView(section)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func sectionView(_ section: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Image(systemName: section.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(section.title)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 0) {
                ForEach(Array(section.entries.enumerated()), id: \.element.id) { idx, entry in
                    HelpRow(entry: entry, onInsert: { onInsert(entry.example) })
                    if idx < section.entries.count - 1 {
                        Divider().opacity(0.15)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .stroke(Color.hairline, lineWidth: 0.5)
            )
        }
    }
}

private struct HelpRow: View {
    let entry: HelpEntry
    let onInsert: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            // Token (monospaced) — fixed-width column to align all rows.
            Text(entry.token)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .foregroundStyle(entry.category.tint)
                .frame(minWidth: 150, alignment: .leading)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.description)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                // The example, click-to-insert. Discoverable by hover.
                Button(action: onInsert) {
                    HStack(spacing: 4) {
                        Text(entry.example)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(entry.category.tint)
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(entry.category.tint.opacity(0.7))
                    }
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(entry.category.tint.opacity(isHovering ? 0.16 : 0.08))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(entry.category.tint.opacity(isHovering ? 0.4 : 0.0),
                                          lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.bmHover) { isHovering = hovering }
                }
                .help("Try this — \(entry.example)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }
}

// MARK: - Previews

#Preview("HelpSheet — light", traits: .fixedLayout(width: 720, height: 560)) {
    HelpSheet(onClose: {}, onInsert: { _ in })
}

#Preview("HelpSheet — dark", traits: .fixedLayout(width: 720, height: 560)) {
    HelpSheet(onClose: {}, onInsert: { _ in })
        .preferredColorScheme(.dark)
}
