import Cocoa
import FinderSync

/// Adds a small handoff command to Finder. The app manages file associations
/// system-wide, so it registers the filesystem root to make the command
/// available in every ordinary Finder location.
final class FinderSync: FIFinderSync {
    private var finderSettings = FinderSettings()
    private var applicationsForMenuTags: [Int: String] = [:]

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
        reloadFinderMenuSetting()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reloadFinderMenuSetting), name: .appSettingsChanged, object: nil)
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        reloadFinderMenuSetting()
        guard finderMenuIsAvailable,
              menuKind == .contextualMenuForItems,
              let url = FIFinderSyncController.default().selectedItemURLs()?.first,
              !url.hasDirectoryPath else { return nil }

        let menu = NSMenu(title: appDisplayName)
        let openWithItem = NSMenuItem(title: appDisplayName, action: nil, keyEquivalent: "")
        let applicationsMenu = NSMenu(title: appDisplayName)
        applicationsForMenuTags.removeAll()
        let fileOverrideBundleIdentifier = finderSettings.finderFileOverrides[url.path]
        let profileDefaultBundleIdentifier = finderSettings.defaultApplicationBundleIdentifier(for: url)
        for application in NSWorkspace.shared.urlsForApplications(toOpen: url) {
            guard let bundleIdentifier = Bundle(url: application)?.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: application.path)
            let title: String
            if bundleIdentifier == fileOverrideBundleIdentifier {
                title = "\(name) (Default for This File)"
            } else if bundleIdentifier == profileDefaultBundleIdentifier {
                title = "\(name) (Default in Current Profile)"
            } else {
                title = name
            }
            let item = NSMenuItem(title: title, action: #selector(chooseApplication(_:)), keyEquivalent: "")
            item.target = self
            let icon = NSWorkspace.shared.icon(forFile: application.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.tag = applicationsForMenuTags.count
            applicationsForMenuTags[item.tag] = bundleIdentifier
            applicationsMenu.addItem(item)
        }
        if applicationsMenu.items.isEmpty {
            openWithItem.title = "Choose Application…"
            openWithItem.action = #selector(chooseApplicationInMainApp(_:))
            openWithItem.target = self
        } else {
            openWithItem.submenu = applicationsMenu
        }
        menu.addItem(openWithItem)
        return menu
    }

    @objc private func chooseApplication(_ sender: NSMenuItem) {
        guard let filePath = FIFinderSyncController.default().selectedItemURLs()?.first?.path,
              let bundleIdentifier = applicationsForMenuTags[sender.tag] else {
            return
        }
        handOffToMainApp(filePath: filePath, applicationBundleIdentifier: bundleIdentifier)
    }

    @objc private func chooseApplicationInMainApp(_ sender: NSMenuItem) {
        guard let filePath = FIFinderSyncController.default().selectedItemURLs()?.first?.path else { return }
        guard let application = NSWorkspace.shared.urlsForApplications(toOpen: URL(fileURLWithPath: filePath)).first,
              let bundleIdentifier = Bundle(url: application)?.bundleIdentifier else { return }
        handOffToMainApp(filePath: filePath, applicationBundleIdentifier: bundleIdentifier)
    }

    /// Finder extensions cannot present the main app's sheet. Prefer an
    /// already-running copy so a stale extension never opens an older host
    /// bundle; otherwise fall back to the app containing this extension.
    private func handOffToMainApp(filePath: String, applicationBundleIdentifier: String) {
        var components = URLComponents(string: "betteropenwith://select")
        components?.queryItems = [
            URLQueryItem(name: "file", value: filePath),
            URLQueryItem(name: "application", value: applicationBundleIdentifier)
        ]
        guard let handoffURL = components?.url else { return }
        let containingApplicationURL = Bundle.main.bundleURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Better Open With.app
        let bundleIdentifier = Bundle(url: containingApplicationURL)?.bundleIdentifier
        let runningApplicationURL = bundleIdentifier.flatMap { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first(where: { !$0.isTerminated })?
                .bundleURL
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([handoffURL], withApplicationAt: runningApplicationURL ?? containingApplicationURL, configuration: configuration)
    }

    @objc private func reloadFinderMenuSetting() {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Better Open With/settings.json")
        if let data = try? Data(contentsOf: settingsURL) {
            finderSettings = (try? JSONDecoder().decode(FinderSettings.self, from: data)) ?? FinderSettings()
        }
    }

    private var appDisplayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "App"
    }

    private var finderMenuIsAvailable: Bool { true }
}

private struct FinderSettings: Decodable {
    var finderMenuEnabled: Bool = true
    var finderProfileDefaults: [String: String] = [:]
    var finderFileOverrides: [String: String] = [:]

    func defaultApplicationBundleIdentifier(for fileURL: URL) -> String? {
        finderFileOverrides[fileURL.path] ?? finderProfileDefaults[fileURL.pathExtension.lowercased()]
    }
}

private extension Notification.Name {
    static let appSettingsChanged = Notification.Name("BetterOpenWith.appSettingsChanged")
}
