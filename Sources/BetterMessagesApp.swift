import SwiftUI
import KeyboardShortcuts

@main
struct BetterMessagesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu bar entry — primary surface area for the app, since there's no Dock icon.
        MenuBarExtra("Better Messages", systemImage: "magnifyingglass.circle.fill") {
            MenuBarContent(appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.menu)

        // Browse window — secondary, opened from the menu (or from a button in the
        // spotlight panel later). Not auto-opened: `LSUIElement = YES` plus `Window`
        // (vs `WindowGroup`) means it only appears when explicitly requested.
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
