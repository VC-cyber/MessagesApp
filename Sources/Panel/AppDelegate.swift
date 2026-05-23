import AppKit
import KeyboardShortcuts

/// App lifecycle owner.
///
/// Responsibilities:
/// - Hold the singleton `SearchViewModel` and `PanelController`.
/// - Register the global hotkey via `KeyboardShortcuts`.
/// - Bootstrap the menu bar item (wired in `BetterMessagesApp.swift` via SwiftUI's
///   `MenuBarExtra`, but the click handlers route through here).
/// - Open the Dashboard on cold launch and when the Dock icon is clicked
///   while no windows are visible.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = SearchViewModel()
    /// Persistent history of recent searches, surfaced in the panel's
    /// empty state. Shared singleton so the same store survives across
    /// panel toggles (the panel can rebuild its View hierarchy on every
    /// show; a per-view store would lose its in-memory cache between
    /// toggles even though UserDefaults would persist).
    let recentSearches = RecentSearchesStore()
    private(set) lazy var panelController = PanelController(
        viewModel: viewModel,
        recentSearches: recentSearches
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire the global hotkey to toggle the spotlight panel.
        KeyboardShortcuts.onKeyDown(for: .toggleSpotlightPanel) { [weak self] in
            self?.panelController.toggle()
        }

        // Cold launch: SwiftUI's first-declared `Window` scene auto-opens, so
        // the Dashboard is already on screen. If for some reason it isn't
        // (e.g. user reset window state), nudge it open as a safety net.
        DispatchQueue.main.async {
            if NSApp.windows.contains(where: { $0.isVisible && !($0 is SpotlightNSPanel) }) {
                return
            }
            WindowOpener.shared.openDashboard()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock-icon click (or "reopen" Apple Event). Open the Dashboard
        // window — this is the entry point users expect from the Dock.
        // The hotkey panel remains the way to summon quick search; Dock
        // clicks deliberately do NOT route to it.
        if !flag {
            WindowOpener.shared.openDashboard()
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func showPanel() { panelController.show() }
    func closePanel() { panelController.close() }
}

/// Bridge between AppKit (this delegate) and SwiftUI (the scene graph) for
/// opening a `Window(id:)` scene programmatically. SwiftUI's `openWindow`
/// environment value is only available inside views, so we capture it from a
/// trivial view at scene-construction time and stash it on this singleton for
/// AppKit callers to invoke later.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    private init() {}

    /// Set by the SwiftUI side once `openWindow` is available.
    var open: ((String) -> Void)?

    /// Convenience for the Dashboard's well-known scene id.
    func openDashboard() {
        open?(WindowID.dashboard)
    }
}
