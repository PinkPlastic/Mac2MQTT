import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = AppConfig.load()
        menuBarController = MenuBarController(config: config)
    }
}

@main
@MainActor
struct Mac2MQTTMain {
    static func main() {
        let app = NSApplication.shared
        // Set as accessory: Runs strictly in the menu bar with NO Dock icon and NO startup window
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
