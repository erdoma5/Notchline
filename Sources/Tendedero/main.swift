import AppKit

MainActor.assumeIsolated {
    // Keep the original app's preferences without taking over its screenshot
    // destination or sharing its saved line of photos.
    let defaults = UserDefaults.standard
    if !defaults.bool(forKey: "notchlineImportedPreferences") {
        let original = UserDefaults(suiteName: "app.tendedero.Tendedero")
        for key in ["clipboardEnabled", "lineSize", "menuBarRevealOff", "quietHang",
                    "soundOff", "keepOnLine", "showOverFullScreen", "extraFolders",
                    "welcomed", "inboxOffered"] {
            if defaults.object(forKey: key) == nil, let value = original?.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "notchlineImportedPreferences")
    }
    defaults.register(defaults: ClipboardWatcher.defaultPreferences)
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
