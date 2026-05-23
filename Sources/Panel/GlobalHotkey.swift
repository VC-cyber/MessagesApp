import KeyboardShortcuts

/// Registered global hotkeys for Better Messages.
///
/// The default summons the spotlight panel. The user can rebind it in
/// Settings via `KeyboardShortcuts.Recorder(for: .toggleSpotlightPanel)`.
extension KeyboardShortcuts.Name {
    /// Default ⌥⇧Space. Chosen because:
    /// - ⌃Space is grabbed by macOS for input-source switching
    /// - ⌘Space is Spotlight
    /// - ⌥Space alone collides with Alfred / Raycast defaults
    /// - ⌥⇧Space is essentially unused by macOS and by common launcher apps
    /// User can still rebind in Settings → KeyboardShortcuts.Recorder.
    static let toggleSpotlightPanel = Self(
        "toggleSpotlightPanel",
        default: .init(.space, modifiers: [.option, .shift])
    )
}
