//
//  EmptyStateSuggestions.swift
//  BetterMessages
//
//  The empty-state "quick filters" row shown when the search field is empty.
//
//  Purpose
//  -------
//  A first-time user opens the panel and sees a search field and… nothing.
//  They might guess to type a word, but they have no idea that `from:Mom`,
//  `type:image`, or `reactions:>=3` exist. This row is the discoverability
//  affordance: clickable pills that *populate the field with the
//  corresponding token*, so the user immediately SEES what's possible.
//
//  Visual
//  ------
//  Solid pill chips, per Apple HIG (glass is reserved for navigation chrome,
//  not content-layer call-to-action buttons). Each pill tinted with its
//  category color from `FilterCategory` so the visual vocabulary is
//  consistent with the filter chips that appear once a query has tokens.
//
//  Layout
//  ------
//  A flowing horizontal row, wrapped in a header text ("Try one of these").
//  The row uses a `FlowLayout`-style wrap so 5–7 pills stay legible at any
//  panel width (the panel's minWidth is 640).
//
//  Why six and not ten:
//    A panel-level row should fit in two visual "rows" worst case on the
//    minimum panel width. Six options give us decent coverage of the
//    discoverability surface (`type:image`, `type:video`, `type:link`,
//    `reactions:>=3`, `last:7d`, and one top-contact slot) without becoming
//    a wall of buttons. Power-users learn the grammar; this is for newcomers.
//

import SwiftUI

/// A single quick-filter button in the empty state. Tapping it populates the
/// search field with the corresponding token.
struct EmptyStateSuggestion: Identifiable, Hashable {
    let id: String
    let label: String
    let icon: String
    let token: String
    let category: FilterCategory

    init(label: String, icon: String, token: String, category: FilterCategory) {
        self.id = token
        self.label = label
        self.icon = icon
        self.token = token
        self.category = category
    }
}

extension EmptyStateSuggestion {
    /// The canonical set of quick-filter suggestions shown in the empty
    /// state. These cover the four largest unknown-by-default surfaces in
    /// the grammar: content type filters, relative date filters, and
    /// reaction count filters.
    static let defaults: [EmptyStateSuggestion] = [
        .init(label: "Photos", icon: "photo.on.rectangle", token: "type:image", category: .type),
        .init(label: "Videos", icon: "video", token: "type:video", category: .type),
        .init(label: "Links", icon: "link", token: "type:link", category: .type),
        .init(label: "Most-reacted", icon: "heart.fill", token: "reactions:>=3", category: .reaction),
        .init(label: "Last 7 days", icon: "calendar", token: "last:7d", category: .dateRange),
        .init(label: "Last 30 days", icon: "calendar.badge.clock", token: "last:30d", category: .dateRange),
    ]
}

struct EmptyStateSuggestions: View {
    let suggestions: [EmptyStateSuggestion]
    let onSelect: (EmptyStateSuggestion) -> Void

    init(
        suggestions: [EmptyStateSuggestion] = EmptyStateSuggestion.defaults,
        onSelect: @escaping (EmptyStateSuggestion) -> Void
    ) {
        self.suggestions = suggestions
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: Space.md) {
            Text("Try one of these")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.6)

            FlowingHStack(spacing: Space.xs) {
                ForEach(suggestions) { suggestion in
                    QuickFilterPill(suggestion: suggestion, action: { onSelect(suggestion) })
                }
            }
            .frame(maxWidth: 520)
        }
    }
}

/// A solid (not-glass) pill button. Per HIG, glass is for navigation chrome;
/// these are content-layer CTAs — solid fills + hairline border, tinted by
/// the filter category so the visual vocabulary matches the filter chips
/// that will appear once the user has typed a query.
private struct QuickFilterPill: View {
    let suggestion: EmptyStateSuggestion
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: suggestion.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(suggestion.category.tint)
                    .symbolRenderingMode(.hierarchical)
                Text(suggestion.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(suggestion.category.tint.opacity(isHovering ? 0.18 : 0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(suggestion.category.tint.opacity(isHovering ? 0.45 : 0.20),
                                  lineWidth: 0.5)
            )
            .scaleEffect(isHovering ? 1.025 : 1.0)
            .animation(.bmHover, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Apply \(suggestion.token)")
    }
}

/// Minimal flowing-HStack: wraps items into multiple rows when the available
/// width is exceeded. Stays simple — we just need a row that wraps cleanly
/// at the panel's minimum width without overflowing.
private struct FlowingHStack: Layout {
    var spacing: CGFloat

    init(spacing: CGFloat = Space.xs) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var rowWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needsSpace = !(rows.last?.isEmpty ?? true)
            let advance = size.width + (needsSpace ? spacing : 0)
            if rowWidth + advance > maxWidth, !(rows.last?.isEmpty ?? true) {
                rows.append([size])
                rowWidth = size.width
            } else {
                rows[rows.count - 1].append(size)
                rowWidth += advance
            }
        }
        var totalHeight: CGFloat = 0
        for (idx, row) in rows.enumerated() {
            let rowHeight = row.map(\.height).max() ?? 0
            totalHeight += rowHeight
            if idx < rows.count - 1 {
                totalHeight += spacing
            }
        }
        var totalWidth: CGFloat = 0
        for row in rows {
            let itemsWidth = row.map(\.width).reduce(0, +)
            let gaps = CGFloat(max(0, row.count - 1)) * spacing
            let rowWidth = itemsWidth + gaps
            if rowWidth > totalWidth { totalWidth = rowWidth }
        }
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        // First, lay out into rows so we know the per-row width and can
        // center each row horizontally within the bounds.
        var rows: [[(idx: Int, size: CGSize)]] = [[]]
        var rowWidth: CGFloat = 0
        for (idx, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needsSpace = !(rows.last?.isEmpty ?? true)
            let advance = size.width + (needsSpace ? spacing : 0)
            if rowWidth + advance > maxWidth, !(rows.last?.isEmpty ?? true) {
                rows.append([(idx, size)])
                rowWidth = size.width
            } else {
                rows[rows.count - 1].append((idx, size))
                rowWidth += advance
            }
        }

        var y = bounds.minY
        for row in rows {
            let rowContentWidth = row.map(\.size.width).reduce(0, +)
                + CGFloat(max(0, row.count - 1)) * spacing
            let rowHeight = row.map(\.size.height).max() ?? 0
            var x = bounds.minX + max(0, (bounds.width - rowContentWidth) / 2)
            for entry in row {
                subviews[entry.idx].place(
                    at: CGPoint(x: x, y: y + (rowHeight - entry.size.height) / 2),
                    proposal: ProposedViewSize(width: entry.size.width, height: entry.size.height)
                )
                x += entry.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

// MARK: - Previews

#Preview("EmptyStateSuggestions — light", traits: .fixedLayout(width: 640, height: 240)) {
    ZStack {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        EmptyStateSuggestions(onSelect: { _ in })
            .padding(Space.xl)
    }
}

#Preview("EmptyStateSuggestions — dark", traits: .fixedLayout(width: 640, height: 240)) {
    ZStack {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        EmptyStateSuggestions(onSelect: { _ in })
            .padding(Space.xl)
    }
    .preferredColorScheme(.dark)
}
