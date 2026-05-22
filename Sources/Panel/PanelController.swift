import AppKit
import SwiftUI

/// Owns the floating spotlight panel — an `NSPanel` rather than a standard
/// `NSWindow` so it doesn't steal first-responder from whatever app the user
/// was just in.
///
/// Lifecycle:
/// - Constructed once by `AppDelegate` at launch.
/// - `toggle()` shows or hides the panel.
/// - The panel is reused across toggles — never recreated — so the search
///   state inside it survives between activations within a session.
@MainActor
final class PanelController: NSObject {
    private var panel: SpotlightNSPanel?
    private let viewModel: SearchViewModel

    init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        positionAtTopCenter(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    // MARK: Panel construction

    private func makePanel() -> SpotlightNSPanel {
        let initialSize = NSSize(width: 720, height: 480)
        let panel = SpotlightNSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow

        let host = NSHostingView(
            rootView: SpotlightPanel(viewModel: viewModel, dismiss: { [weak self] in
                self?.close()
            })
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host

        return panel
    }

    private func positionAtTopCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let panelSize = panel.frame.size
        // Slightly above true center, like Spotlight.
        let x = visible.midX - panelSize.width / 2
        let y = visible.maxY - panelSize.height - visible.height * 0.18
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// `NSPanel` subclass that can become key and accept text input despite the
/// `.nonactivatingPanel` style mask, and that dismisses on Esc.
final class SpotlightNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Esc → hide. Reusing the panel preserves state for next time.
        self.orderOut(nil)
    }
}
