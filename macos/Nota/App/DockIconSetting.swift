import AppKit

/// The owner's "Hide Nota from the Dock" switch. Stored as a bool under
/// "notaHideDockIcon"; absent reads as shown, which is what every owner saw
/// before the switch existed.
///
/// Hidden means the `.accessory` activation policy: no Dock icon and no ⌘-Tab
/// entry, while the menu-bar item and every window keep working. The way back
/// to the window is the menu-bar item's "Open Nota", since a Dock click is the
/// thing that is gone.
enum DockIconSetting {
  static let defaultsKey = "notaHideDockIcon"

  static var isHidden: Bool {
    UserDefaults.standard.bool(forKey: defaultsKey)
  }

  static func apply(hidden: Bool) {
    let policy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
    guard NSApp.activationPolicy() != policy else { return }
    NSApp.setActivationPolicy(policy)
    // Leaving `.regular` deactivates the app, which sends the Settings window
    // the owner just flipped this in behind whatever is underneath. Taking
    // focus back keeps it where they were looking.
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}
