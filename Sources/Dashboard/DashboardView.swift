//
//  DashboardView.swift
//  BetterMessages
//
//  Top-level Dashboard window content. Composes the header (overview stats +
//  window selector), the frequency chart, and the two top-N lists.
//
//  Layout:
//    ┌─────────────────────────────────────────────────────────────┐
//    │ Dashboard      [30d 12m All]                                │
//    │ <stat tiles row: total / sent / received / chats / span>    │
//    ├─────────────────────────────────────────────────────────────┤
//    │  ┌─────────────────────────────────────────────────────────┐│
//    │  │ Texting frequency           <chart>                     ││
//    │  └─────────────────────────────────────────────────────────┘│
//    │  ┌───────────────────────────┐  ┌────────────────────────┐ │
//    │  │ People you text the most  │  │ Group chats you text…  │ │
//    │  │   <ranked list>           │  │   <ranked list>        │ │
//    │  └───────────────────────────┘  └────────────────────────┘ │
//    └─────────────────────────────────────────────────────────────┘
//

import SwiftUI

struct DashboardView: View {

    /// Reuse one VM across open/close cycles of the dashboard window so we
    /// don't re-open chat.db each time. The VM is StateObject-ish via
    /// @State on the @Observable instance.
    @State private var viewModel = DashboardViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                content
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
        .background(Color.chromeBackground)
        .onAppear {
            viewModel.bootstrapIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dashboard")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.primary)
                    if let span = spanLabel {
                        Text(span)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                WindowSelector(selection: $viewModel.window)
            }

            statTiles
        }
    }

    private var spanLabel: String? {
        guard let stats = viewModel.stats,
              let oldest = stats.overview.oldest,
              let newest = stats.overview.newest else {
            return viewModel.isLoading ? "Loading…" : nil
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "All time: \(formatter.string(from: oldest)) → \(formatter.string(from: newest))"
    }

    private var statTiles: some View {
        let stats = viewModel.stats?.overview
        return GlassCard(cornerRadius: Radius.large, showsBorder: true) {
            HStack(alignment: .top, spacing: Space.xl) {
                StatTile(
                    label: "Total messages",
                    value: formatBig(stats?.total),
                    caption: viewModel.stats != nil ? "all time" : nil
                )
                Divider().frame(height: 56)
                StatTile(
                    label: "Sent",
                    value: formatBig(stats?.sent),
                    caption: sentPctLabel
                )
                Divider().frame(height: 56)
                StatTile(
                    label: "Received",
                    value: formatBig(stats?.received),
                    caption: receivedPctLabel
                )
                Divider().frame(height: 56)
                StatTile(
                    label: "Conversations",
                    value: formatBig(stats?.chats),
                    caption: stats != nil ? "chats" : nil
                )
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
        }
    }

    private var sentPctLabel: String? {
        guard let s = viewModel.stats?.overview, s.total > 0 else { return nil }
        return String(format: "%.1f%%", Double(s.sent) / Double(s.total) * 100.0)
    }

    private var receivedPctLabel: String? {
        guard let s = viewModel.stats?.overview, s.total > 0 else { return nil }
        return String(format: "%.1f%%", Double(s.received) / Double(s.total) * 100.0)
    }

    private func formatBig(_ n: Int?) -> String {
        guard let n else { return "—" }
        return n.formatted(.number.grouping(.automatic))
    }

    // MARK: - Content panels

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.setupError {
            errorPanel(error)
        } else if viewModel.stats == nil && viewModel.isLoading {
            ProgressView("Loading dashboard…")
                .frame(maxWidth: .infinity)
                .padding(Space.xxl)
        } else if let stats = viewModel.stats {
            VStack(alignment: .leading, spacing: Space.lg) {
                frequencyPanel(stats: stats)
                HStack(alignment: .top, spacing: Space.lg) {
                    peoplePanel(stats: stats)
                    groupsPanel(stats: stats)
                }
            }
        }
    }

    private func frequencyPanel(stats: DashboardStats) -> some View {
        StatPanel(
            title: "Texting frequency",
            subtitle: subtitle(for: viewModel.window),
            accessory: {
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            },
            content: {
                FrequencyChart(
                    buckets: stats.timeSeries,
                    bucketing: viewModel.window.bucketing
                )
            }
        )
    }

    private func peoplePanel(stats: DashboardStats) -> some View {
        StatPanel(
            title: "People you text the most",
            subtitle: peopleSubtitle(stats: stats)
        ) {
            TopList(
                entries: stats.topContacts.map { stat in
                    TopListEntry(
                        id: stat.key,
                        displayName: stat.displayName,
                        primary: stat.total,
                        secondaryPair: .init(left: stat.sent, right: stat.received),
                        secondaryLabel: nil
                    )
                },
                primaryLabel: "Total",
                secondaryLeftLabel: "Sent",
                secondaryRightLabel: "Received",
                emptyMessage: "No 1:1 chats in this window."
            )
        }
    }

    private func groupsPanel(stats: DashboardStats) -> some View {
        StatPanel(
            title: "Group chats you text the most",
            subtitle: groupsSubtitle(stats: stats)
        ) {
            TopList(
                entries: stats.topGroups.map { stat in
                    TopListEntry(
                        id: "group:\(stat.chatRowID)",
                        displayName: stat.displayName,
                        primary: stat.sentByYou,
                        secondaryPair: nil,
                        secondaryLabel: "\(stat.sentByYou.formatted(.number)) sent · \(stat.total.formatted(.number)) total"
                    )
                },
                primaryLabel: "Sent by you",
                secondaryLeftLabel: nil,
                secondaryRightLabel: nil,
                emptyMessage: "No group chats in this window."
            )
        }
    }

    private func errorPanel(_ message: String) -> some View {
        GlassCard(cornerRadius: Radius.large, showsBorder: true) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    Image(systemName: "lock.shield")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("Can't open Messages")
                        .font(.headline)
                }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Better Messages needs Full Disk Access to read your iMessage history. Click the button — Finder will reveal Better Messages.app; drag it into the Full Disk Access list, enable, then relaunch.")
                    .font(.callout)
                    .foregroundStyle(.primary)
                Button("Grant Full Disk Access") {
                    openFullDiskAccessSettingsAndRevealApp()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Subtitle helpers

    private func subtitle(for window: DashboardLoader.Window) -> String {
        switch window {
        case .last30Days:   return "Last 30 days · daily"
        case .last12Months: return "Last 12 months · monthly"
        case .allTime:      return "All time · monthly"
        }
    }

    private func peopleSubtitle(stats: DashboardStats) -> String {
        if stats.topContacts.isEmpty { return "Top 12, 1:1 conversations" }
        return "Top \(stats.topContacts.count), 1:1 conversations · \(viewModel.window.label)"
    }

    private func groupsSubtitle(stats: DashboardStats) -> String {
        if stats.topGroups.isEmpty { return "Ranked by your sent count" }
        return "Top \(stats.topGroups.count) · ranked by your sent count · \(viewModel.window.label)"
    }
}

#Preview("DashboardView — empty state") {
    DashboardView()
        .frame(width: 1200, height: 800)
}
