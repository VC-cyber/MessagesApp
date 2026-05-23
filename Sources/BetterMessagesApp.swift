import SwiftUI
import KeyboardShortcuts

@main
struct BetterMessagesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Dashboard — the primary windowed surface. Declared FIRST so SwiftUI
        // treats it as the default scene: opens on cold launch and reopens
        // when the user clicks the Dock icon while no windows are visible.
        // Generous default size so the chart and two top-lists fit
        // side-by-side without crowding; a smaller min size keeps it usable
        // when the user shrinks the window down.
        Window("Dashboard", id: WindowID.dashboard) {
            DashboardView()
                .frame(minWidth: 900, minHeight: 620)
                .containerBackground(.thinMaterial, for: .window)
                // Publish `openWindow` to AppKit so AppDelegate can open the
                // Dashboard on Dock-click (see `WindowOpener`).
                .background(WindowOpenerBridge())
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)

        // Menu bar entry — secondary, ever-present surface for quick access
        // to the panel, the browser, and Settings.
        MenuBarExtra("Better Messages", systemImage: "magnifyingglass.circle.fill") {
            MenuBarContent(appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.menu)

        // Browse window — secondary, opened from the menu bar or from a
        // button in the spotlight panel. `Window` (vs `WindowGroup`) means it
        // only appears when explicitly requested.
        Window("Better Messages", id: WindowID.browser) {
            ContentView()
                .frame(minWidth: 960, minHeight: 620)
                // Let macOS 26's window-level glass show through. The window
                // itself becomes the deepest glass surface; everything inside
                // floats above it.
                .containerBackground(.thinMaterial, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)

        // Settings — currently just hotkey rebinding. SettingsLink in the menu
        // bar pops this up.
        Settings {
            SettingsView()
        }
    }
}

/// String IDs for SwiftUI scenes. Keep them centralized so callers don't
/// duplicate magic strings.
enum WindowID {
    static let browser = "browser"
    static let dashboard = "dashboard"
}

// MARK: - Menu bar content

private struct MenuBarContent: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Search…") {
            appDelegate.showPanel()
        }
        // Visual hint in the menu — the actual global binding is registered by
        // `KeyboardShortcuts` in AppDelegate and works even when this menu isn't open.
        .keyboardShortcut("m", modifiers: [.command, .control])

        Divider()

        Button("Open Browser") {
            openWindow(id: WindowID.browser)
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Dashboard…") {
            openWindow(id: WindowID.dashboard)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Better Messages") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettingsPane: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Toggle search panel:", name: .toggleSpotlightPanel)
            } header: {
                Text("Hotkey")
            } footer: {
                Text("Summons the Better Messages search panel from anywhere on macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(height: 200)
    }
}

// MARK: - AppKit ↔ SwiftUI window-open bridge

/// Invisible helper view that captures SwiftUI's `openWindow` action and
/// hands it to `WindowOpener.shared`, so AppKit code (e.g. AppDelegate
/// responding to a Dock-icon click) can open SwiftUI windows by id.
private struct WindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                WindowOpener.shared.open = { id in
                    openWindow(id: id)
                }
            }
    }
}
