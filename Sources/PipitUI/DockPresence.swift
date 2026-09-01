import AppKit

/// Whether this process shows a Dock icon and appears in the app switcher.
///
/// Held here rather than in the runtime because the activation policy is an
/// AppKit fact about the process, not a decision the pipeline makes, and
/// `PipitCore` imports only Foundation.
public enum DockPresence {
    /// The policy for a setting and for whether a window is open.
    ///
    /// A window on screen makes Pipit a regular application whatever the
    /// setting says, because macOS hands activation back only to applications
    /// that have a Dock icon. Measured on macOS 26 with a window open and
    /// another application quitting in front of it: as an accessory
    /// application, focus went to the last regular application and the window
    /// stayed buried with no Dock icon and no app switcher entry to reach it;
    /// as a regular application, focus came back to the window. That is the
    /// setup wizard sinking behind everything when a permission prompt closes.
    public static func policy(
        showsDockIcon: Bool, hasOpenWindow: Bool
    ) -> NSApplication.ActivationPolicy {
        showsDockIcon || hasOpenWindow ? .regular : .accessory
    }

    /// Puts the policy into force. Re-applying the policy already in force makes
    /// the app flicker out of and back into the Dock, and this runs on every
    /// settings change and every window opening, so an unchanged value returns
    /// early.
    @MainActor
    public static func apply(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}
