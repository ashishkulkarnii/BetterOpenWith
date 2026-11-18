import Cocoa
import Carbon

@main
enum BetterOpenWithApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var mainViewController: MainViewController?
    private var statusItem: NSStatusItem?
    private var isReallyQuitting = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        let controller = MainViewController()
        let window = NSWindow(contentViewController: controller)
        window.title = AppIdentity.displayName
        window.setContentSize(NSSize(width: 680, height: 560))
        window.minSize = NSSize(width: 560, height: 350)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        mainViewController = controller
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appSettingsChanged), name: .appSettingsChanged, object: nil)
        appSettingsChanged()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppSettings.current.keepRunningInMenuBar, !isReallyQuitting else { return .terminateNow }
        mainWindow?.orderOut(nil)
        return .terminateCancel
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(receive)
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: value) else { return }
        receive(url)
    }


    private func receive(_ incomingURL: URL) {
        let url: URL
        var applicationBundleIdentifier: String?
        if incomingURL.scheme == "betteropenwith",
           let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false),
           let path = components.queryItems?.first(where: { $0.name == "file" })?.value {
            url = URL(fileURLWithPath: path)
            applicationBundleIdentifier = components.queryItems?.first(where: { $0.name == "application" })?.value
        } else {
            url = incomingURL
        }
        if let applicationBundleIdentifier {
            mainViewController?.handleFinderSelection(fileURL: url, applicationBundleIdentifier: applicationBundleIdentifier)
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            mainViewController?.selectFile(url: url)
        }
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.title = AppIdentity.displayName
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AppIdentity.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        showMainWindow(settings: true)
    }

    @objc private func updateMenuBarItem() {
        if AppSettings.current.keepRunningInMenuBar {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSApp.applicationIconImage
                item.button?.image?.isTemplate = false
                item.button?.image?.accessibilityDescription = AppIdentity.displayName
                let menu = NSMenu()
                menu.addItem(withTitle: "Open \(AppIdentity.displayName)", action: #selector(openFromMenuBar), keyEquivalent: "")
                menu.addItem(.separator())
                menu.addItem(withTitle: "Quit \(AppIdentity.displayName)", action: #selector(quitForReal), keyEquivalent: "q")
                menu.items.forEach { $0.target = self }
                item.menu = menu
                statusItem = item
            }
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func appSettingsChanged() {
        updateMenuBarItem()
        mainViewController?.applyWindowAppearance()
    }

    @objc private func openFromMenuBar() { showMainWindow(settings: false) }

    private func showMainWindow(settings: Bool) {
        if settings { mainViewController?.showSettings() }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitForReal() {
        isReallyQuitting = true
        NSApp.terminate(nil)
    }
}
