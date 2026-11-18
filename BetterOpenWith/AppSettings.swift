import Foundation

enum AppIdentity {
    static let displayName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? "App"
}

struct AppSettings: Codable {
    enum Theme: String, Codable { case system, light, dark }
    enum WindowBackground: String, Codable { case opaque, transparent }

    var finderMenuEnabled: Bool
    var keepRunningInMenuBar: Bool
    var theme: Theme
    var windowBackground: WindowBackground
    var experimentalFileOverrides: Bool
    var finderProfileDefaults: [String: String]
    var finderFileOverrides: [String: String]

    init(finderMenuEnabled: Bool = true, keepRunningInMenuBar: Bool = true, theme: Theme = .system, windowBackground: WindowBackground = .opaque, experimentalFileOverrides: Bool = false, finderProfileDefaults: [String: String] = [:], finderFileOverrides: [String: String] = [:]) {
        self.finderMenuEnabled = finderMenuEnabled
        self.keepRunningInMenuBar = keepRunningInMenuBar
        self.theme = theme
        self.windowBackground = windowBackground
        self.experimentalFileOverrides = experimentalFileOverrides
        self.finderProfileDefaults = finderProfileDefaults
        self.finderFileOverrides = finderFileOverrides
    }

    enum CodingKeys: String, CodingKey { case finderMenuEnabled, keepRunningInMenuBar, theme, windowBackground, experimentalFileOverrides, finderProfileDefaults, finderFileOverrides }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        finderMenuEnabled = try values.decodeIfPresent(Bool.self, forKey: .finderMenuEnabled) ?? true
        keepRunningInMenuBar = try values.decodeIfPresent(Bool.self, forKey: .keepRunningInMenuBar) ?? true
        theme = try values.decodeIfPresent(Theme.self, forKey: .theme) ?? .system
        windowBackground = try values.decodeIfPresent(WindowBackground.self, forKey: .windowBackground) ?? .opaque
        experimentalFileOverrides = try values.decodeIfPresent(Bool.self, forKey: .experimentalFileOverrides) ?? false
        finderProfileDefaults = try values.decodeIfPresent([String: String].self, forKey: .finderProfileDefaults) ?? [:]
        finderFileOverrides = try values.decodeIfPresent([String: String].self, forKey: .finderFileOverrides) ?? [:]
    }

    static let applicationSupportDirectory: URL = {
        let fileManager = FileManager.default
        let parent = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = parent.appendingPathComponent("Better Open With", isDirectory: true)
        let legacyURL = parent.appendingPathComponent("Default App Selector", isDirectory: true)
        if !fileManager.fileExists(atPath: url.path), fileManager.fileExists(atPath: legacyURL.path) {
            try? fileManager.copyItem(at: legacyURL, to: url)
        }
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let settingsURL = applicationSupportDirectory.appendingPathComponent("settings.json")
    private static let profilesDirectoryKey = "profiles-directory-url"

    static var current: AppSettings {
        guard let data = try? Data(contentsOf: settingsURL), let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    static func save(_ settings: AppSettings) {
        try? JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
        NotificationCenter.default.post(name: .appSettingsChanged, object: nil)
        DistributedNotificationCenter.default().post(name: .appSettingsChanged, object: nil)
    }

    static var profilesDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: profilesDirectoryKey) { return URL(fileURLWithPath: path, isDirectory: true) }
        if let legacyPath = UserDefaults(suiteName: "io.github.ashishkulkarnii.DefaultAppSelector")?.string(forKey: profilesDirectoryKey) {
            UserDefaults.standard.set(legacyPath, forKey: profilesDirectoryKey)
            return URL(fileURLWithPath: legacyPath, isDirectory: true)
        }
        return applicationSupportDirectory.appendingPathComponent("Profiles", isDirectory: true)
    }

    static func setProfilesDirectory(_ directory: URL) {
        UserDefaults.standard.set(directory.path, forKey: profilesDirectoryKey)
    }

    static func publishFinderProfile(_ profile: DefaultsProfile) {
        let defaults = Dictionary(uniqueKeysWithValues: profile.associations.map { ($0.fileExtension.lowercased(), $0.applicationBundleIdentifier) })
        var settings = current
        let overrides = settings.experimentalFileOverrides
            ? Dictionary(uniqueKeysWithValues: (profile.fileOverrides ?? []).map { ($0.filePath, $0.applicationBundleIdentifier) })
            : [:]
        guard settings.finderProfileDefaults != defaults || settings.finderFileOverrides != overrides else { return }
        settings.finderProfileDefaults = defaults
        settings.finderFileOverrides = overrides
        save(settings)
    }
}

extension Notification.Name {
    static let appSettingsChanged = Notification.Name("BetterOpenWith.appSettingsChanged")
}
