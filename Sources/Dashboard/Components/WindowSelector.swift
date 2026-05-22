//
//  WindowSelector.swift
//  BetterMessages — Dashboard components
//
//  Pill row for the time window: 30d / 12m / All. Subtle glass on the
//  selected pill, hairline on the unselected ones. Uses the system accent
//  for selection so the OS-level tint propagates.
//

import SwiftUI

struct WindowSelector: View {
    @Binding var selection: DashboardLoader.Window

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(DashboardLoader.Window.allCases) { window in
                    Button {
                        withAnimation(.bmGlassMorph) {
                            selection = window
                        }
                    } label: {
                        Text(window.label)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, Space.md)
                            .padding(.vertical, 6)
                            .foregroundStyle(selection == window ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .background {
                        if selection == window {
                            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                                .glassEffect(
                                    .regular.tint(Color.accentColor.opacity(0.22)),
                                    in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                                )
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: Radius.medium))
                    .accessibilityLabel("Show \(window.label) window")
                    .accessibilityAddTraits(selection == window ? .isSelected : [])
                }
            }
            .padding(3)
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 0.5)
        )
    }
}

#Preview("WindowSelector", traits: .fixedLayout(width: 360, height: 80)) {
    StatefulPreviewWrapper(DashboardLoader.Window.last30Days) { selection in
        WindowSelector(selection: selection)
            .padding(Space.lg)
            .background(Color.chromeBackground)
    }
}

/// Tiny helper for previews — wraps state so we can drive @Binding.
private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    private let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.content = content
    }

    var body: some View {
        content($value)
    }
}
