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

    /// The screen for the saved choice. Falls back to the built-in (notch) screen,
    /// then to the main screen, when the saved monitor is unplugged.
    static func current() -> NSScreen {
        screen(for: .saved)
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
