import AppKit

/// Whether this process shows a Dock icon and appears in the app switcher.
///
/// Held here rather than in the runtime because the activation policy is an
/// AppKit fact about the process, not a decision the pipeline makes, and
/// `MeetTapeCore` imports only Foundation. Applied at launch and again whenever
/// settings change, so the icon appears and disappears without a relaunch.
public enum DockPresence {
    /// Sets the policy the setting asks for. Re-applying the policy already in
    /// force makes the app flicker out of and back into the Dock, and this runs
    /// on every settings change, so an unchanged value returns early.
    @MainActor
    public static func apply(showsDockIcon: Bool) {
        let wanted: NSApplication.ActivationPolicy = showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }
}
