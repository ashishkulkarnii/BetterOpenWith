import AppKit
import UniformTypeIdentifiers

struct DefaultAssociation: Codable, Hashable {
    var fileExtension: String
    var displayName: String
    var typeIdentifier: String
    var applicationBundleIdentifier: String
}

struct FileOverride: Codable, Hashable, Identifiable {
    var id: UUID
    var filePath: String
    var displayName: String
    var applicationBundleIdentifier: String
}

struct DefaultsProfile: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var isAppleBaseline: Bool
    var associations: [DefaultAssociation]
    var fileOverrides: [FileOverride]?
}

enum FileTypeCatalog {
    static let common = [
        ("pdf", "PDF document", "com.adobe.pdf"), ("txt", "Plain text", "public.plain-text"),
        ("rtf", "Rich Text Format", "public.rtf"), ("md", "Markdown", "net.daringfireball.markdown"),
        ("html", "HTML document", "public.html"), ("json", "JSON document", "public.json"),
        ("xml", "XML document", "public.xml"), ("csv", "Comma-separated values", "public.comma-separated-values-text"),
        ("docx", "Word document", "org.openxmlformats.wordprocessingml.document"), ("xlsx", "Excel workbook", "org.openxmlformats.spreadsheetml.sheet"),
        ("pptx", "PowerPoint presentation", "org.openxmlformats.presentationml.presentation"), ("pages", "Pages document", "com.apple.iwork.pages.sffpages"),
        ("jpg", "JPEG image", "public.jpeg"), ("png", "PNG image", "public.png"), ("gif", "GIF image", "com.compuserve.gif"),
        ("heic", "HEIC image", "public.heic"), ("svg", "SVG image", "public.svg-image"),
        ("mp3", "MP3 audio", "public.mp3"), ("m4a", "MPEG-4 audio", "public.mpeg-4-audio"),
        ("wav", "WAV audio", "com.microsoft.waveform-audio"), ("mp4", "MPEG-4 video", "public.mpeg-4"),
        ("mov", "QuickTime movie", "com.apple.quicktime-movie"), ("zip", "ZIP archive", "public.zip-archive"),
        ("ics", "Calendar event", "com.apple.ical.ics")
    ]

    static func typeIdentifier(for extensionName: String) -> String? {
        let normalized = extensionName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !normalized.isEmpty else { return nil }
        return UTType(filenameExtension: normalized)?.identifier
    }
}

final class DefaultsProfileStore {
    private let activeProfileKey = "active-defaults-profile-v1"
    private let defaults: UserDefaults
    private let directory: URL

    init(defaults: UserDefaults = .standard, directory: URL = AppSettings.profilesDirectory) {
        self.defaults = defaults
        self.directory = directory
        if defaults.string(forKey: activeProfileKey) == nil,
           let legacyProfileID = UserDefaults(suiteName: "io.github.ashishkulkarnii.DefaultAppSelector")?.string(forKey: activeProfileKey) {
            defaults.set(legacyProfileID, forKey: activeProfileKey)
        }
        createAppleBaselineIfNeeded()
    }

    var profiles: [DefaultsProfile] {
        (try? JSONDecoder().decode([DefaultsProfile].self, from: Data(contentsOf: profilesFileURL))) ?? []
    }

    var activeProfile: DefaultsProfile {
        let all = profiles
        guard let value = defaults.string(forKey: activeProfileKey), let id = UUID(uuidString: value),
              let profile = all.first(where: { $0.id == id }) else {
            return all.first(where: { $0.isAppleBaseline }) ?? all[0]
        }
        return profile
    }

    func activate(_ profile: DefaultsProfile) { defaults.set(profile.id.uuidString, forKey: activeProfileKey) }

    func hasProfile(named name: String) -> Bool {
        profiles.contains { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    func nextDefaultProfileName() -> String { uniqueDefaultName(for: "Custom Defaults") }

    func createProfile(named name: String, copying profile: DefaultsProfile) -> DefaultsProfile {
        let resolvedName = uniqueDefaultName(for: name)
        let result = DefaultsProfile(id: UUID(), name: resolvedName, isAppleBaseline: false, associations: profile.associations, fileOverrides: profile.fileOverrides)
        persist(profiles + [result])
        activate(result)
        return result
    }

    func save(_ profile: DefaultsProfile) {
        var all = profiles
        guard let index = all.firstIndex(where: { $0.id == profile.id }) else { return }
        all[index] = profile
        persist(all)
        activate(profile)
    }

    func delete(_ profile: DefaultsProfile) {
        guard !profile.isAppleBaseline else { return }
        persist(profiles.filter { $0.id != profile.id })
        if defaults.string(forKey: activeProfileKey) == profile.id.uuidString { defaults.removeObject(forKey: activeProfileKey) }
    }

    private func createAppleBaselineIfNeeded() {
        guard profiles.isEmpty else { return }
        let associations = FileTypeCatalog.common.compactMap { ext, name, typeID -> DefaultAssociation? in
            guard let type = UTType(typeID), let app = NSWorkspace.shared.urlForApplication(toOpen: type),
                  let bundleID = Bundle(url: app)?.bundleIdentifier else { return nil }
            return DefaultAssociation(fileExtension: ext, displayName: name, typeIdentifier: typeID, applicationBundleIdentifier: bundleID)
        }
        let apple = DefaultsProfile(id: UUID(), name: "Apple Defaults (first-run snapshot)", isAppleBaseline: true, associations: associations, fileOverrides: [])
        persist([apple])
        activate(apple)
    }

    private var profilesFileURL: URL { directory.appendingPathComponent("profiles.json") }

    private func uniqueDefaultName(for requestedName: String) -> String {
        guard requestedName == "Custom Defaults" else { return requestedName }
        let existing = profiles.map(\ .name)
        guard existing.contains(where: { $0.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else { return requestedName }
        var index = 2
        while existing.contains(where: { $0.compare("Custom Defaults \(index)", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) { index += 1 }
        return "Custom Defaults \(index)"
    }

    private func persist(_ profiles: [DefaultsProfile]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(profiles).write(to: profilesFileURL, options: .atomic)
    }
}
