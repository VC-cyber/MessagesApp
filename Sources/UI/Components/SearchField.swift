import SwiftUI

/// The hero search field. Big rounded liquid-glass pill at the top of the
/// detail pane. Hosts inline filter chips before the typing cursor.
///
/// Filter chips are passed in as an array of `ActiveFilter` and rendered inside
/// the same glass surface as the text field, wrapped in a `GlassEffectContainer`
/// so they morph smoothly as the user adds/removes them.
struct SearchField: View {
    /// A single active filter, identifiable so SwiftUI can animate add/remove.
    struct ActiveFilter: Identifiable, Hashable {
        let id: UUID
        let category: FilterCategory
        let label: String

        init(id: UUID = UUID(), category: FilterCategory, label: String) {
            self.id = id
            self.category = category
            self.label = label
        }
    }

    @Binding var text: String
    var filters: [ActiveFilter] = []
    var placeholder: String = "Search messages, people, dates…"
    var onRemoveFilter: ((ActiveFilter) -> Void)? = nil
    var onSubmit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: Space.md) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                    .animation(.bmDefault, value: isFocused)
                    .accessibilityHidden(true)

                // Inline filter chips
                if !filters.isEmpty {
                    HStack(spacing: Space.xs) {
                        ForEach(filters) { filter in
                            FilterChip(
                                category: filter.category,
                                label: filter.label,
                                onDismiss: onRemoveFilter.map { remove in
                                    { remove(filter) }
                                }
                            )
                            .transition(
                                .asymmetric(
                                    insertion: .scale(scale: 0.6).combined(with: .opacity),
                                    removal: .scale(scale: 0.6).combined(with: .opacity)
                                )
                            )
                        }
                    }
                }

                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .onSubmit { onSubmit?() }
                    .submitLabel(.search)

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                    .help("Clear search")
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, 14)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(isFocused ? 0.45 : 0.0),
                        lineWidth: 1.5
                    )
                    .animation(.bmDefault, value: isFocused)
                    .allowsHitTesting(false)
            }
            .animation(.bmGlassMorph, value: filters)
            .animation(.bmDefault, value: text.isEmpty)
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
        }
    }
}

// MARK: - Previews

private struct SearchFieldPreviewWrapper: View {
    @State var text: String
    @State var filters: [SearchField.ActiveFilter]
    var body: some View {
        SearchField(
            text: $text,
            filters: filters,
            onRemoveFilter: { f in
                withAnimation(.bmGlassMorph) {
                    filters.removeAll { $0.id == f.id }
                }
            }
        )
        .padding(Space.xl)
    }
}

#Preview("SearchField — empty", traits: .fixedLayout(width: 760, height: 140)) {
    ZStack {
        LinearGradient(
            colors: [.orange.opacity(0.4), .pink.opacity(0.45), .purple.opacity(0.55)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        SearchFieldPreviewWrapper(text: "", filters: [])
    }
}

#Preview("SearchField — with chips", traits: .fixedLayout(width: 760, height: 140)) {
    ZStack {
        LinearGradient(
            colors: [.teal.opacity(0.5), .cyan.opacity(0.5), .blue.opacity(0.55)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        SearchFieldPreviewWrapper(
            text: "flight",
            filters: [
                .init(category: .person, label: "Mom"),
                .init(category: .dateRange, label: "Last 30 days"),
            ]
        )
    }
}

#Preview("SearchField — dark", traits: .fixedLayout(width: 760, height: 140)) {
    ZStack {
        LinearGradient(
            colors: [.indigo.opacity(0.6), .black],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        SearchFieldPreviewWrapper(
            text: "",
            filters: [.init(category: .chat, label: "Vegas planning")]
        )
    }
    .preferredColorScheme(.dark)
}
