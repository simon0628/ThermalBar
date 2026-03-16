import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
