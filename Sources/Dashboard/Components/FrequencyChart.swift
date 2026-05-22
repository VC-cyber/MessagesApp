//
//  FrequencyChart.swift
//  BetterMessages — Dashboard components
//
//  Swift Charts line + area chart of sent vs received messages over time.
//  Built on the public `Charts` framework (macOS 13+, polished on macOS 26).
//
//  Visual:
//    - Two stacked area lines (sent in accent, received in secondary)
//    - Hover tooltip overlays the date and exact counts
//    - Y axis stays clean (no chart noise), X axis adapts to bucketing
//

import SwiftUI
import Charts

struct FrequencyChart: View {
    let buckets: [DashboardStats.TimeBucket]
    let bucketing: DashboardLoader.Bucketing

    /// Live hover position — drives the tooltip rule + selection ring.
    @State private var hoverDate: Date?

    var body: some View {
        if buckets.isEmpty {
            emptyState
        } else {
            chartBody
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        Chart {
            ForEach(buckets) { b in
                LineMark(
                    x: .value("Date", b.date),
                    y: .value("Sent", b.sent),
                    series: .value("Series", "Sent")
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2.0))
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("Date", b.date),
                    y: .value("Sent", b.sent),
                    series: .value("Series", "Sent")
                )
                .foregroundStyle(LinearGradient(
                    colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Date", b.date),
                    y: .value("Received", b.received),
                    series: .value("Series", "Received")
                )
                .foregroundStyle(Color.secondary.opacity(0.95))
                .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [3, 2]))
                .interpolationMethod(.monotone)
            }

            if let hoverDate, let bucket = nearestBucket(to: hoverDate) {
                RuleMark(x: .value("Hover", bucket.date))
                    .foregroundStyle(Color.primary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))

                PointMark(
                    x: .value("Hover sent", bucket.date),
                    y: .value("Sent", bucket.sent)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(64)

                PointMark(
                    x: .value("Hover received", bucket.date),
                    y: .value("Received", bucket.received)
                )
                .foregroundStyle(Color.secondary)
                .symbolSize(48)
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(xAxisLabel(for: date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let intVal = value.as(Int.self) {
                        Text(intVal.formatted(.number.notation(.compactName)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            // Convert hover x to date via Charts proxy.
                            if let plotFrame = proxy.plotFrame {
                                let origin = geo[plotFrame].origin
                                let relativeX = p.x - origin.x
                                if let date: Date = proxy.value(atX: relativeX) {
                                    hoverDate = date
                                } else {
                                    hoverDate = nil
                                }
                            }
                        case .ended:
                            hoverDate = nil
                        }
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            tooltip
                .padding(.top, 4)
                .padding(.trailing, 4)
        }
        .frame(minHeight: 220, idealHeight: 260)
    }

    private var tooltip: some View {
        Group {
            if let hoverDate, let bucket = nearestBucket(to: hoverDate) {
                HStack(spacing: Space.md) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tooltipDateLabel(for: bucket.date))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                        .frame(height: 22)
                    legendDot(.accentColor, label: "Sent", value: bucket.sent)
                    legendDot(.secondary, label: "Received", value: bucket.received)
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .strokeBorder(Color.hairline, lineWidth: 0.5)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                // Static legend when not hovering.
                HStack(spacing: Space.md) {
                    legendDot(.accentColor, label: "Sent", value: nil)
                    legendDot(.secondary, label: "Received", value: nil)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .animation(.bmHover, value: hoverDate)
    }

    @ViewBuilder
    private func legendDot(_ color: Color, label: String, value: Int?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            if let value {
                Text(value.formatted(.number))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No activity in this window")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    /// Find the bucket with the smallest |date difference| to the hover point.
    /// Buckets are ordered ascending; we could binary-search but the lists
    /// stay small (max ~365 for 30-day daily / 12 for monthly).
    private func nearestBucket(to date: Date) -> DashboardStats.TimeBucket? {
        guard !buckets.isEmpty else { return nil }
        var best = buckets[0]
        var bestDelta = abs(best.date.timeIntervalSince(date))
        for b in buckets.dropFirst() {
            let d = abs(b.date.timeIntervalSince(date))
            if d < bestDelta {
                bestDelta = d
                best = b
            }
        }
        return best
    }

    private func xAxisLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        switch bucketing {
        case .day:
            formatter.dateFormat = "MMM d"
        case .week:
            formatter.dateFormat = "MMM d"
        case .month:
            formatter.dateFormat = "MMM ''yy"
        }
        return formatter.string(from: date)
    }

    private func tooltipDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        switch bucketing {
        case .day:
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        case .week:
            formatter.dateFormat = "'Week of' MMM d, yyyy"
        case .month:
            formatter.dateFormat = "MMMM yyyy"
        }
        return formatter.string(from: date)
    }
}

// MARK: - Previews

#Preview("FrequencyChart — daily", traits: .fixedLayout(width: 720, height: 320)) {
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())
    let buckets = (0..<30).map { offset -> DashboardStats.TimeBucket in
        let day = cal.date(byAdding: .day, value: -29 + offset, to: today) ?? today
        let sent = max(0, 30 + Int(sin(Double(offset) * 0.4) * 18 + Double.random(in: -5...5)))
        let received = max(0, 25 + Int(cos(Double(offset) * 0.32) * 14 + Double.random(in: -4...4)))
        return DashboardStats.TimeBucket(date: day, sent: sent, received: received)
    }
    return FrequencyChart(buckets: buckets, bucketing: .day)
        .padding(Space.lg)
        .background(Color.chromeBackground)
}
