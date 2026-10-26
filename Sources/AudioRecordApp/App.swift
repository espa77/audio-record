import AppKit

@main
@MainActor
enum AudioRecordApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar app: no Dock icon, no main window
        app.run()
    }
}
