//
//  TopList.swift
//  BetterMessages — Dashboard components
//
//  Vertical list of "ranking" rows — used for both "People you text the most"
//  and "Group chats you text the most". Each row shows an avatar circle
//  (initials), a primary label, a secondary breakdown line, and a
//  proportional bar relative to the top entry.
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

    struct SecondaryPair: Equatable {
        let left: Int
        let right: Int
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

            // Avatar — initials in a colored circle. Stable hue per name.
            AvatarCircle(name: entry.displayName)

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

// MARK: - Previews

#Preview("TopList — people", traits: .fixedLayout(width: 520, height: 480)) {
    TopList(
        entries: [
            .init(id: "1", displayName: "Henry Wu", primary: 1284, secondaryPair: .init(left: 612, right: 672), secondaryLabel: nil),
            .init(id: "2", displayName: "Amma Satyajit", primary: 1102, secondaryPair: .init(left: 501, right: 601), secondaryLabel: nil),
            .init(id: "3", displayName: "Alex Chen", primary: 612, secondaryPair: .init(left: 315, right: 297), secondaryLabel: nil),
            .init(id: "4", displayName: "+14155550100", primary: 308, secondaryPair: .init(left: 142, right: 166), secondaryLabel: nil),
        ],
        primaryLabel: "Total",
        secondaryLeftLabel: "Sent",
        secondaryRightLabel: "Received",
        emptyMessage: "No contacts in this window."
    )
    .padding(Space.lg)
    .background(Color.chromeBackground)
}
