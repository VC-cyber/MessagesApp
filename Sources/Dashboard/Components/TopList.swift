//
//  TopList.swift
//  BetterMessages — Dashboard components
//
//  Vertical list of "ranking" rows — used for both "People you text the most"
//  and "Group chats you text the most". Each row shows an avatar circle
//  (photo when available, initials fallback for people; custom group photo
//  OR stacked composite of participants for groups), a primary label, a
//  secondary breakdown line, and a proportional bar relative to the top
//  entry.
//
//  Per HIG (and the spec): rows are solid + hairline borders, NOT glass.
//

import SwiftUI

/// A view-friendly contract — both `ContactStat` and `GroupStat` map onto this
/// so we can render them with a single component.
struct TopListEntry: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Primary numeric value used for ranking (and bar width).
    let primary: Int
    /// Optional pair of secondary numbers — e.g. "423 sent / 312 received".
    /// Stored as a struct (not a tuple) so the row is Equatable for SwiftUI.
    let secondaryPair: SecondaryPair?
    /// Optional plain secondary line — used when secondaryPair isn't relevant.
    let secondaryLabel: String?
    /// What kind of avatar to draw on the leading edge.
    let avatar: Avatar

    init(
        id: String,
        displayName: String,
        primary: Int,
        secondaryPair: SecondaryPair?,
        secondaryLabel: String?,
        avatar: Avatar = .none
    ) {
        self.id = id
        self.displayName = displayName
        self.primary = primary
        self.secondaryPair = secondaryPair
        self.secondaryLabel = secondaryLabel
        self.avatar = avatar
    }

    struct SecondaryPair: Equatable {
        let left: Int
        let right: Int
    }

    /// Three rendering modes, picked by the caller:
    /// - `.person(photo:)`  — a `ContactStat`, photo bytes or nil → initials.
    /// - `.groupPhoto(_:)`  — a `GroupStat` with a custom group photo set.
    /// - `.groupComposite(participants:)` — a `GroupStat` with no custom
    ///   photo: stack the first few participants' avatars.
    /// - `.none`            — used by previews / unknown rows.
    enum Avatar: Equatable {
        case none
        case person(photo: Data?)
        case groupPhoto(Data)
        case groupComposite(participants: [Data?])
    }
}

struct TopList: View {
    let entries: [TopListEntry]
    let primaryLabel: String           // e.g. "Total" or "Sent"
    let secondaryLeftLabel: String?    // e.g. "Sent"
    let secondaryRightLabel: String?   // e.g. "Received"
    let emptyMessage: String

    /// Max value across the list — used to scale every bar relative to the top.
    private var maxPrimary: Int {
        entries.map(\.primary).max() ?? 0
    }

    var body: some View {
        if entries.isEmpty {
            HStack {
                Image(systemName: "tray")
                    .foregroundStyle(.tertiary)
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Space.md)
        } else {
            VStack(spacing: Space.sm) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                    row(rank: idx + 1, entry: entry)
                }
            }
        }
    }

    @ViewBuilder
    private func row(rank: Int, entry: TopListEntry) -> some View {
        HStack(spacing: Space.md) {
            // Rank dot
            Text("\(rank)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            // Avatar — photo when we have one, initials/composite/generic
            // when we don't.
            avatarView(for: entry)

            // Labels + bar
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Space.sm)
                    Text(formatCount(entry.primary))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                }

                // Proportional bar — relative to the top entry's value.
                ProportionalBar(
                    value: entry.primary,
                    max: maxPrimary
                )
                .frame(height: 6)

                // Secondary line
                if let pair = entry.secondaryPair,
                   let left = secondaryLeftLabel,
                   let right = secondaryRightLabel {
                    HStack(spacing: Space.md) {
                        labeledNumber(left, pair.left)
                        labeledNumber(right, pair.right)
                        Spacer()
                    }
                } else if let secondaryLabel = entry.secondaryLabel {
                    Text(secondaryLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, Space.xs)
        .contentShape(Rectangle())
    }

    /// Pick the right avatar visual for an entry.
    ///
    /// We size everyone at 36pt to match the row height. The composite
    /// `GroupAvatarView` lays out 2-3 circles within the same 36pt box.
    @ViewBuilder
    private func avatarView(for entry: TopListEntry) -> some View {
        let size: CGFloat = 36
        switch entry.avatar {
        case .none:
            AvatarCircle(name: entry.displayName, size: size)
        case .person(let photo):
            AvatarView(
                imageData: photo,
                initials: initials(from: entry.displayName),
                size: size,
                tint: stableTint(for: entry.displayName),
                initialsForeground: .white
            )
        case .groupPhoto(let bytes):
            AvatarView(
                imageData: bytes,
                initials: groupInitials(from: entry.displayName),
                size: size,
                tint: stableTint(for: entry.displayName),
                initialsForeground: .white
            )
        case .groupComposite(let participants):
            GroupAvatarView(
                participantAvatars: participants,
                groupName: entry.displayName,
                size: size
            )
        }
    }

    private func labeledNumber(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(formatCount(value))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// Formats counts with thin-space grouping; small numbers render as-is.
    private func formatCount(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    /// One- or two-letter monogram for an individual contact, derived from
    /// the first letter of each name part.
    private func initials(from name: String) -> String {
        let parts = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        if letters.isEmpty { return "?" }
        return letters.joined().uppercased()
    }

    /// Monogram for a named group. We use the first letter of the first
    /// emoji-or-letter run. Falls back to a person glyph indirectly via
    /// `AvatarView` — passing "?" here causes the view to show "?".
    private func groupInitials(from name: String) -> String {
        // Trim leading whitespace and punctuation; take the first scalar
        // that's a letter or symbol. If none, return "?" which renders as
        // the placeholder monogram.
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for ch in trimmed {
            if ch.isLetter { return String(ch).uppercased() }
            if !ch.isWhitespace && !ch.isPunctuation { return String(ch) }
        }
        return "?"
    }

    /// Deterministic tint per name — same input always lands on the same
    /// hue. Matches the design used in `AvatarCircle` for legacy callers.
    private func stableTint(for name: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.40, green: 0.55, blue: 0.92),
            Color(red: 0.55, green: 0.40, blue: 0.85),
            Color(red: 0.92, green: 0.50, blue: 0.50),
            Color(red: 0.40, green: 0.70, blue: 0.55),
            Color(red: 0.85, green: 0.65, blue: 0.35),
            Color(red: 0.55, green: 0.65, blue: 0.85),
            Color(red: 0.75, green: 0.45, blue: 0.65),
            Color(red: 0.45, green: 0.65, blue: 0.45),
        ]
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// Solid horizontal bar showing `value / max`. Uses the accent color with a
/// subtle hairline background fill so empty bars are still visible.
struct ProportionalBar: View {
    let value: Int
    let max: Int

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.85),
                            Color.accentColor.opacity(0.55)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: geo.size.width * fraction)
            }
        }
    }

    private var fraction: CGFloat {
        guard max > 0 else { return 0 }
        return CGFloat(value) / CGFloat(max)
    }
}

/// Avatar circle showing 1-2 initials in a hue derived from the contact name.
/// Stable for any given name (same person → same color across launches).
///
/// **Kept for the no-data preview** in this file and as a legacy fallback for
/// `TopListEntry.Avatar.none`. The Dashboard's real rendering goes through
/// `AvatarView` (photo or initials) via `TopListEntry.Avatar.person`.
struct AvatarCircle: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [hue.opacity(0.85), hue.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text(initials)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(
            Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var initials: String {
        let parts = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        if letters.isEmpty { return "?" }
        return letters.joined().uppercased()
    }

    /// Deterministic hue from the name — same name always lands on the same
    /// color across launches. We use a small palette of muted hues that
    /// look good on both light and dark backgrounds.
    private var hue: Color {
        let palette: [Color] = [
            Color(red: 0.40, green: 0.55, blue: 0.92),  // blue
            Color(red: 0.55, green: 0.40, blue: 0.85),  // purple
            Color(red: 0.92, green: 0.50, blue: 0.50),  // coral
            Color(red: 0.40, green: 0.70, blue: 0.55),  // teal
            Color(red: 0.85, green: 0.65, blue: 0.35),  // amber
            Color(red: 0.55, green: 0.65, blue: 0.85),  // sky
            Color(red: 0.75, green: 0.45, blue: 0.65),  // magenta
            Color(red: 0.45, green: 0.65, blue: 0.45),  // green
        ]
        var hash: UInt64 = 5381
        for byte in name.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// Composite avatar for a group chat with no custom photo.
///
/// Mirrors Messages.app's stacked-circle pattern: 2 or 3 participant
/// avatars overlapping inside the row's avatar slot. A participant with
/// no AddressBook photo contributes a tinted-monogram placeholder so the
/// composite still reads as "a group" rather than blank circles.
///
/// Layout:
/// - 1 participant available: one circle at native size (rare in practice
///   — most groups have ≥3 participants; this case mostly happens when
///   AddressBook is sparse).
/// - 2 participants: two ~70%-size circles, top-leading and bottom-trailing.
/// - 3+ participants: three ~58%-size circles in a triangle (top-leading,
///   top-trailing, bottom-center).
///
/// We render placeholders (the SF Symbol `person.crop.circle.fill`) for
/// nil slots rather than collapsing them out — preserves the "this is a
/// group" silhouette even when AddressBook is sparse.
struct GroupAvatarView: View {
    /// Up to 3 raw PNG/JPEG byte blobs. Nil entries become placeholders.
    let participantAvatars: [Data?]
    /// Group name — used to derive a deterministic background tint when
    /// every participant is a placeholder, so the composite still has a
    /// recognizable color.
    let groupName: String
    /// Total diameter of the composite.
    let size: CGFloat

    var body: some View {
        ZStack {
            // Background plate — soft tinted disc so the composite reads
            // as a unified avatar even with placeholder slots.
            Circle()
                .fill(backgroundTint.opacity(0.25))
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .strokeBorder(Color.hairline, lineWidth: 0.5)
                )

            // The participants laid out per the count.
            switch min(participantAvatars.count, 3) {
            case 0:
                // No participants at all — show a single generic group glyph
                // so we never render a bare tinted disc.
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.secondary)
            case 1:
                participantCircle(
                    bytes: participantAvatars[0],
                    diameter: size * 0.78
                )
            case 2:
                ZStack {
                    participantCircle(
                        bytes: participantAvatars[0],
                        diameter: size * 0.62
                    )
                    .offset(x: -size * 0.14, y: -size * 0.14)
                    participantCircle(
                        bytes: participantAvatars[1],
                        diameter: size * 0.62
                    )
                    .offset(x: size * 0.14, y: size * 0.14)
                }
            default:
                ZStack {
                    participantCircle(
                        bytes: participantAvatars[0],
                        diameter: size * 0.52
                    )
                    .offset(x: -size * 0.18, y: -size * 0.16)
                    participantCircle(
                        bytes: participantAvatars[1],
                        diameter: size * 0.52
                    )
                    .offset(x: size * 0.18, y: -size * 0.16)
                    participantCircle(
                        bytes: participantAvatars[2],
                        diameter: size * 0.52
                    )
                    .offset(x: 0, y: size * 0.20)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// One participant circle. Photo if we have one, generic glyph if we
    /// don't — never empty.
    @ViewBuilder
    private func participantCircle(bytes: Data?, diameter: CGFloat) -> some View {
        if let bytes, let image = NSImage(data: bytes) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.18), radius: 1.2, y: 0.5)
        } else {
            ZStack {
                Circle()
                    .fill(backgroundTint.opacity(0.85))
                Image(systemName: "person.fill")
                    .font(.system(size: diameter * 0.55, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: diameter, height: diameter)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.18), radius: 1.2, y: 0.5)
        }
    }

    /// Deterministic tint from the group name — same group always lands on
    /// the same color. Same palette as `AvatarCircle`.
    private var backgroundTint: Color {
        let palette: [Color] = [
            Color(red: 0.40, green: 0.55, blue: 0.92),
            Color(red: 0.55, green: 0.40, blue: 0.85),
            Color(red: 0.92, green: 0.50, blue: 0.50),
            Color(red: 0.40, green: 0.70, blue: 0.55),
            Color(red: 0.85, green: 0.65, blue: 0.35),
            Color(red: 0.55, green: 0.65, blue: 0.85),
            Color(red: 0.75, green: 0.45, blue: 0.65),
            Color(red: 0.45, green: 0.65, blue: 0.45),
        ]
        var hash: UInt64 = 5381
        for byte in groupName.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

// MARK: - Previews

#Preview("TopList — people", traits: .fixedLayout(width: 520, height: 480)) {
    TopList(
        entries: [
            .init(id: "1", displayName: "Henry Wu", primary: 1284, secondaryPair: .init(left: 612, right: 672), secondaryLabel: nil, avatar: .person(photo: nil)),
            .init(id: "2", displayName: "Amma Satyajit", primary: 1102, secondaryPair: .init(left: 501, right: 601), secondaryLabel: nil, avatar: .person(photo: nil)),
            .init(id: "3", displayName: "Alex Chen", primary: 612, secondaryPair: .init(left: 315, right: 297), secondaryLabel: nil, avatar: .person(photo: nil)),
            .init(id: "4", displayName: "+14155550100", primary: 308, secondaryPair: .init(left: 142, right: 166), secondaryLabel: nil, avatar: .person(photo: nil)),
        ],
        primaryLabel: "Total",
        secondaryLeftLabel: "Sent",
        secondaryRightLabel: "Received",
        emptyMessage: "No contacts in this window."
    )
    .padding(Space.lg)
    .background(Color.chromeBackground)
}

#Preview("TopList — groups", traits: .fixedLayout(width: 520, height: 320)) {
    TopList(
        entries: [
            .init(id: "g1", displayName: "Dashboard Group", primary: 421, secondaryPair: nil, secondaryLabel: "421 sent · 1,283 total", avatar: .groupComposite(participants: [nil, nil, nil])),
            .init(id: "g2", displayName: "Family", primary: 203, secondaryPair: nil, secondaryLabel: "203 sent · 502 total", avatar: .groupComposite(participants: [nil, nil])),
            .init(id: "g3", displayName: "lost causes", primary: 88, secondaryPair: nil, secondaryLabel: "88 sent · 211 total", avatar: .groupComposite(participants: [nil])),
        ],
        primaryLabel: "Sent",
        secondaryLeftLabel: nil,
        secondaryRightLabel: nil,
        emptyMessage: "No group chats in this window."
    )
    .padding(Space.lg)
    .background(Color.chromeBackground)
}
