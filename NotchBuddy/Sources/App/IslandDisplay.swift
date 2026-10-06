import AppKit

extension Notification.Name {
    /// Posted when the user picks another display for the island in Settings.
    static let islandDisplayChanged = Notification.Name("islandDisplayChanged")
}

/// Which display the island lives on. Saved in UserDefaults as a string:
/// "builtin", "main", or "screen:<NSScreenNumber>".
enum IslandDisplayChoice: Hashable {
    case builtIn
    case main
    case screen(CGDirectDisplayID)

    static let defaultsKey = "islandDisplay"

    init(rawValue: String) {
        if rawValue == "main" {
            self = .main
        } else if rawValue.hasPrefix("screen:"), let id = UInt32(rawValue.dropFirst(7)) {
            self = .screen(id)
        } else {
            self = .builtIn
        }
    }

    var rawValue: String {
        switch self {
        case .builtIn:        return "builtin"
        case .main:           return "main"
        case .screen(let id): return "screen:\(id)"
        }
    }

    static var saved: IslandDisplayChoice {
        get { IslandDisplayChoice(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: .islandDisplayChanged, object: nil)
        }
    }
}

/// Single place that decides which NSScreen hosts the island.
@MainActor
enum IslandDisplay {

    /// Set while an alert is shown on the display you're working on, away from the saved one.
    static var alertScreenID: CGDirectDisplayID?

    /// The screen the island is on: the alert's display while one is showing there, else the
    /// saved choice. Falls back to the built-in (notch) screen, then to the main screen,
    /// when the saved monitor is unplugged.
    static func current() -> NSScreen {
        if let id = alertScreenID, let s = NSScreen.screens.first(where: { displayID(of: $0) == id }) {
            return s
        }
        return screen(for: .saved)
    }

    /// The display you're working on: where the frontmost app's top window sits, else the
    /// one under the mouse. NSScreen.main can't tell from a background app (it reports the
    /// menu-bar display). Window bounds need no Screen Recording permission.
    static func activeScreen() -> NSScreen? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]],
           let primaryHeight = NSScreen.screens.first?.frame.height,
           let top = windows.first(where: {
               ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
           }),
           let bounds = top[kCGWindowBounds as String] as? [String: CGFloat],
           let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] {
            // CG window bounds start at the top-left of the primary display; AppKit at its bottom-left.
            let center = NSPoint(x: x + w / 2, y: primaryHeight - y - h / 2)
            if let s = NSScreen.screens.first(where: { NSPointInRect(center, $0.frame) }) { return s }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    static func screen(for choice: IslandDisplayChoice) -> NSScreen {
        switch choice {
        case .builtIn:
            break
        case .main:
            // NSScreen.main follows keyboard focus; screens[0] is the menu-bar display.
            if let s = NSScreen.screens.first { return s }
        case .screen(let id):
            if let s = NSScreen.screens.first(where: { displayID(of: $0) == id }) { return s }
        }
        return builtInScreen() ?? NSScreen.screens.first ?? NSScreen.main!
    }

    /// The screen with a camera notch, else the laptop's built-in panel.
    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.screens.first { CGDisplayIsBuiltin(displayID(of: $0)) != 0 }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
