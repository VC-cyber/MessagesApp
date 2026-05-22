import AppKit
import KeyboardShortcuts

/// App lifecycle owner.
///
/// Responsibilities:
/// - Hold the singleton `SearchViewModel` and `PanelController`.
/// - Register the global hotkey via `KeyboardShortcuts`.
/// - Bootstrap the menu bar item (wired in `BetterMessagesApp.swift` via SwiftUI's
///   `MenuBarExtra`, but the click handlers route through here).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = SearchViewModel()
    private(set) lazy var panelController = PanelController(viewModel: viewModel)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire the global hotkey to toggle the spotlight panel.
        KeyboardShortcuts.onKeyDown(for: .toggleSpotlightPanel) { [weak self] in
            self?.panelController.toggle()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopen (e.g. clicking a Dock icon — though we have none) shows the panel.
        panelController.show()
        return true
    }

    func showPanel() { panelController.show() }
    func closePanel() { panelController.close() }
}
