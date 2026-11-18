import Foundation
import Darwin
import XCTest
@testable import Better_Open_With

final class BetterOpenWithTests: XCTestCase {
    func testFileTypeCatalogNormalizesExtensions() {
        XCTAssertEqual(FileTypeCatalog.typeIdentifier(for: " pdf "), "com.adobe.pdf")
        XCTAssertEqual(FileTypeCatalog.typeIdentifier(for: ".PDF"), "com.adobe.pdf")
        XCTAssertNil(FileTypeCatalog.typeIdentifier(for: "   "))
    }

    func testDefaultAssociationRoundTrip() throws {
        let association = DefaultAssociation(
            fileExtension: "pdf",
            displayName: "PDF document",
            typeIdentifier: "com.adobe.pdf",
            applicationBundleIdentifier: "com.apple.Preview"
        )
        let decoded = try JSONDecoder().decode(DefaultAssociation.self, from: JSONEncoder().encode(association))
        XCTAssertEqual(decoded, association)
    }

    func testFileOverrideRoundTrip() throws {
        let override = FileOverride(
            id: UUID(),
            filePath: "/tmp/example.pdf",
            displayName: "example.pdf",
            applicationBundleIdentifier: "com.apple.Preview"
        )
        let decoded = try JSONDecoder().decode(FileOverride.self, from: JSONEncoder().encode(override))
        XCTAssertEqual(decoded, override)
    }

    func testProfileRoundTripPreservesBothKindsOfRules() throws {
        let profile = DefaultsProfile(
            id: UUID(),
            name: "Writing",
            isAppleBaseline: false,
            associations: [sampleAssociation(extension: "txt")],
            fileOverrides: [sampleOverride(path: "/tmp/notes.txt")]
        )

        let decoded = try JSONDecoder().decode(DefaultsProfile.self, from: JSONEncoder().encode(profile))

        XCTAssertEqual(decoded, profile)
    }

    func testLegacySettingsDisableExperimentalFileOverrides() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.experimentalFileOverrides)
        XCTAssertTrue(settings.finderMenuEnabled)
        XCTAssertTrue(settings.keepRunningInMenuBar)
    }

    func testSettingsRoundTripPreservesFinderRules() throws {
        let settings = AppSettings(
            finderMenuEnabled: false,
            keepRunningInMenuBar: false,
            theme: .dark,
            windowBackground: .transparent,
            experimentalFileOverrides: true,
            finderProfileDefaults: ["pdf": "com.apple.Preview"],
            finderFileOverrides: ["/tmp/example.pdf": "com.google.Chrome"]
        )

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.finderMenuEnabled, false)
        XCTAssertEqual(decoded.keepRunningInMenuBar, false)
        XCTAssertEqual(decoded.theme, .dark)
        XCTAssertEqual(decoded.windowBackground, .transparent)
        XCTAssertTrue(decoded.experimentalFileOverrides)
        XCTAssertEqual(decoded.finderProfileDefaults, settings.finderProfileDefaults)
        XCTAssertEqual(decoded.finderFileOverrides, settings.finderFileOverrides)
    }

    func testStoreCreatesProfileWithUniqueDefaultNameAndCopiesRules() throws {
        try withIsolatedProfileStore { store, baseline in
            let first = store.createProfile(named: "Custom Defaults", copying: baseline)
            let second = store.createProfile(named: "Custom Defaults", copying: baseline)

            XCTAssertEqual(first.name, "Custom Defaults")
            XCTAssertEqual(second.name, "Custom Defaults 2")
            XCTAssertEqual(first.associations, baseline.associations)
            XCTAssertEqual(first.fileOverrides, baseline.fileOverrides)
            XCTAssertEqual(store.activeProfile.id, second.id)
        }
    }

    func testStoreSavesActivatesAndDeletesCustomProfiles() throws {
        try withIsolatedProfileStore { store, baseline in
            var custom = store.createProfile(named: "Work", copying: baseline)
            custom.associations = [sampleAssociation(extension: "md")]
            store.save(custom)

            XCTAssertEqual(store.activeProfile, custom)
            XCTAssertEqual(store.profiles.first(where: { $0.id == custom.id })?.associations, custom.associations)

            store.delete(custom)
            XCTAssertNil(store.profiles.first(where: { $0.id == custom.id }))
            XCTAssertEqual(store.activeProfile.id, baseline.id)
        }
    }

    func testStoreDoesNotDeleteAppleBaseline() throws {
        try withIsolatedProfileStore { store, baseline in
            store.delete(baseline)

            XCTAssertEqual(store.profiles, [baseline])
        }
    }

    func testQuarantineIsAbsentForNewFile() throws {
        try withTemporaryFile { url in
            XCTAssertFalse(QuarantineFileAccess.hasAttribute(at: url))
        }
    }

    func testQuarantineDetectionAndRemoval() throws {
        try withTemporaryFile { url in
            try addQuarantineAttribute(to: url)
            XCTAssertTrue(QuarantineFileAccess.hasAttribute(at: url))

            XCTAssertNil(QuarantineFileAccess.remove(from: url))
            XCTAssertFalse(QuarantineFileAccess.hasAttribute(at: url))
        }
    }

    func testRemovingMissingQuarantineIsHarmless() throws {
        try withTemporaryFile { url in
            XCTAssertNil(QuarantineFileAccess.remove(from: url))
        }
    }

    private func withTemporaryFile(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("test".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func withIsolatedProfileStore(_ body: (DefaultsProfileStore, DefaultsProfile) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "BetterOpenWithTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let baseline = DefaultsProfile(
            id: UUID(),
            name: "Apple Defaults (first-run snapshot)",
            isAppleBaseline: true,
            associations: [sampleAssociation(extension: "txt")],
            fileOverrides: [sampleOverride(path: "/tmp/notes.txt")]
        )

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([baseline]).write(to: directory.appendingPathComponent("profiles.json"))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        try body(DefaultsProfileStore(defaults: defaults, directory: directory), baseline)
    }

    private func sampleAssociation(extension fileExtension: String) -> DefaultAssociation {
        DefaultAssociation(
            fileExtension: fileExtension,
            displayName: "Document",
            typeIdentifier: "public.plain-text",
            applicationBundleIdentifier: "com.apple.TextEdit"
        )
    }

    private func sampleOverride(path: String) -> FileOverride {
        FileOverride(
            id: UUID(),
            filePath: path,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            applicationBundleIdentifier: "com.apple.TextEdit"
        )
    }

    private func addQuarantineAttribute(to url: URL) throws {
        let value = Data("0083;00000000;BetterOpenWithTests;https://example.invalid".utf8)
        let result = value.withUnsafeBytes { bytes in
            setxattr(url.path, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not add a quarantine attribute to the test file."])
        }
    }
}
