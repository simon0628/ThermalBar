import AppKit

// Run as menu-bar-only app: no Dock icon, no app menu
NSApplication.shared.setActivationPolicy(.accessory)

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
