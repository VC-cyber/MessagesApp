import SwiftUI

/// Root view for Better Messages.
///
/// Composition:
/// - `NavigationSplitView` sidebar with sectioned filters
/// - Detail pane: hero search field (with inline chips), then results list,
///   then empty / loading / results states.
///
/// Uses placeholder `PreviewMessage` data — features-agent's `SearchViewModel`
/// will replace it during integration. See `docs/design-notes.md`.
struct ContentView: View {
    enum SidebarSelection: Hashable {
        case allMessages
        case people
        case groupChats
        case pinned
        case timeRange(TimeRange)
    }

    enum TimeRange: String, Hashable, CaseIterable {
        case last7 = "Last 7 days"
        case last30 = "Last 30 days"
        case thisYear = "This year"
        case allTime = "All time"

        var icon: String { self == .allTime ? "infinity" : "calendar" }
    }

    @State private var sidebarSelection: SidebarSelection = .allMessages
    @State private var query: String = ""
    @State private var filters: [SearchField.ActiveFilter] = [
        .init(category: .person, label: "Mom"),
        .init(category: .dateRange, label: "Last 30 days"),
    ]
    @State private var selectedResult: PreviewMessage.ID?

    private let messages = PreviewData.messages

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
        }
        .navigationTitle("Better Messages")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        switch sidebarSelection {
        case .allMessages: return "All Messages"
        case .people: return "People"
        case .groupChats: return "Group Chats"
        case .pinned: return "Pinned"
        case .timeRange(let r): return r.rawValue
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("Library")
                SidebarItem(
                    label: "All Messages",
                    systemImage: "tray.full",
                    count: 12_483,
                    isSelected: sidebarSelection == .allMessages
                )
                .onTapGesture { sidebarSelection = .allMessages }

                SidebarItem(
                    label: "People",
                    systemImage: "person.2",
                    count: 247,
                    isSelected: sidebarSelection == .people
                )
                .onTapGesture { sidebarSelection = .people }

                SidebarItem(
                    label: "Group Chats",
                    systemImage: "person.3",
                    count: 18,
                    isSelected: sidebarSelection == .groupChats
                )
                .onTapGesture { sidebarSelection = .groupChats }

                SidebarItem(
                    label: "Pinned",
                    systemImage: "pin.fill",
                    isSelected: sidebarSelection == .pinned
                )
                .onTapGesture { sidebarSelection = .pinned }

                sectionHeader("Time Range").padding(.top, Space.md)
                ForEach(TimeRange.allCases, id: \.self) { range in
                    SidebarItem(
                        label: range.rawValue,
                        systemImage: range.icon,
                        isSelected: sidebarSelection == .timeRange(range)
                    )
                    .onTapGesture {
                        sidebarSelection = .timeRange(range)
                        // Sync to filter chips for date ranges other than .allTime
                        if range != .allTime {
                            addOrReplaceFilter(.init(category: .dateRange, label: range.rawValue))
                        }
                    }
                }

                Spacer(minLength: Space.xl)
            }
            .padding(.vertical, Space.md)
            .padding(.horizontal, Space.sm)
        }
        .scrollContentBackground(.hidden)
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Space.md)
            .padding(.bottom, Space.xs)
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            // Hero search field — the only "navigation-layer" glass in the detail pane.
            SearchField(
                text: $query,
                filters: filters,
                onRemoveFilter: { f in
                    withAnimation(.bmGlassMorph) {
                        filters.removeAll { $0.id == f.id }
                    }
                }
            )
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.md)

            // Result count / status line
            if !messages.isEmpty {
                resultStatusLine
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.sm)
            }

            Divider().opacity(0.3)

            // Results / empty state
            if filteredMessages.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.chromeBackground)
    }

    private var filteredMessages: [PreviewMessage] {
        guard !query.isEmpty else { return messages }
        return messages.filter { msg in
            msg.body.localizedCaseInsensitiveContains(query)
                || msg.sender.localizedCaseInsensitiveContains(query)
                || msg.chatName.localizedCaseInsensitiveContains(query)
        }
    }

    private var resultStatusLine: some View {
        HStack(spacing: Space.sm) {
            Text("\(filteredMessages.count) results")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if !query.isEmpty {
                Text("for \u{201C}\(query)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Button("Newest first") {}
                Button("Oldest first") {}
                Button("Most relevant") {}
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
                    .font(.subheadline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: Space.sm) {
                ForEach(filteredMessages) { msg in
                    ResultRow(
                        message: msg,
                        isSelected: selectedResult == msg.id,
                        onTap: { selectedResult = msg.id }
                    )
                }
            }
            .padding(Space.lg)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)

            Text("No results")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)

            Text("Try adjusting your filters, or search a different phrase.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            GlassEffectContainer(spacing: 14) {
                HStack(spacing: Space.sm) {
                    suggestionChip("flight", category: .freeText)
                    suggestionChip("birthday", category: .freeText)
                    suggestionChip("Mom", category: .person)
                }
            }
            .padding(.top, Space.md)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xl)
    }

    private func suggestionChip(_ label: String, category: FilterCategory) -> some View {
        Button {
            withAnimation(.bmGlassMorph) {
                if category == .freeText {
                    query = label
                } else {
                    addOrReplaceFilter(.init(category: category, label: label))
                }
            }
        } label: {
            FilterChip(category: category, label: label)
        }
        .buttonStyle(.plain)
    }

    private func addOrReplaceFilter(_ filter: SearchField.ActiveFilter) {
        withAnimation(.bmGlassMorph) {
            filters.removeAll { $0.category == filter.category }
            filters.append(filter)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1180, height: 760)
}

#Preview("ContentView — dark") {
    ContentView()
        .frame(width: 1180, height: 760)
        .preferredColorScheme(.dark)
}
