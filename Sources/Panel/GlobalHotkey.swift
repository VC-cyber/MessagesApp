import KeyboardShortcuts

/// Registered global hotkeys for Better Messages.
///
/// The default summons the spotlight panel. The user can rebind it in
/// Settings via `KeyboardShortcuts.Recorder(for: .toggleSpotlightPanel)`.
extension KeyboardShortcuts.Name {
    static let toggleSpotlightPanel = Self(
        "toggleSpotlightPanel",
        default: .init(.m, modifiers: [.control, .command])
    )
}
