import AppKit
import Darwin
import FinderSync
import ServiceManagement
import UniformTypeIdentifiers

final class MainViewController: NSViewController, NSComboBoxDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Mode { case file, fileExtension }
    private var store = DefaultsProfileStore()
    private var mode: Mode = .fileExtension
    private var fileURL: URL?
    private var typeID: String?
    private var fileExtension = "pdf"
    private var apps: [URL] = []
    private var currentDefaults: [DefaultAssociation] = []
    private var fileOverrides: [FileOverride] = []
    private var profileWindow: NSWindowController?
    private var tabs: NSTabViewController?
    private weak var keepRunningToggle: NSButton?
    private let windowBackground = NSVisualEffectView()

    private let source = NSSegmentedControl(labels: ["File", "Extension"], trackingMode: .selectOne, target: nil, action: nil)
    private let chooseFile = NSButton(title: "Choose File…", target: nil, action: nil)
    private let selectedFile = NSTextField(labelWithString: "No file selected")
    private let extensionField = NSComboBox()
    private let targetDetailsTable = NSTableView()
    private let appPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let makeDefault = NSButton(checkboxWithTitle: "Make this the system default", target: nil, action: nil)
    private let fileRuleNote = NSTextField(wrappingLabelWithString: "Experimental: saving changes Finder’s launch preference for this file only. To apply the change reliably for downloaded files, the app must remove the file’s macOS quarantine marker after saving.")
    private let systemProfiles = NSPopUpButton(frame: .zero, pullsDown: false)
    private let editingProfiles = NSPopUpButton(frame: .zero, pullsDown: false)
    private let profileWriteHint = NSTextField(labelWithString: "")
    private let viewingProfiles = NSPopUpButton(frame: .zero, pullsDown: false)
    private let save = NSButton(title: "Save", target: nil, action: nil)
    private let saveOpen = NSButton(title: "Save & Open", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "Enter an extension or choose a file.")
    private let defaultsTable = NSTableView()
    private let fileOverridesTable = NSTableView()

    override func loadView() {
        let root = NSView(); root.wantsLayer = true
        windowBackground.material = .underWindowBackground; windowBackground.blendingMode = .behindWindow; windowBackground.state = .active; windowBackground.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(windowBackground)
        NSLayoutConstraint.activate([windowBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor), windowBackground.trailingAnchor.constraint(equalTo: root.trailingAnchor), windowBackground.topAnchor.constraint(equalTo: root.topAnchor), windowBackground.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        view = root
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        setupControls(); buildTabs(); reloadProfiles(); refreshDefaults(); updateFileOverrideExperimentUI(); sourceChanged(); selectExtension("pdf")
    }

    private func setupControls() {
        source.selectedSegment = 1; source.target = self; source.action = #selector(sourceChanged)
        chooseFile.target = self; chooseFile.action = #selector(chooseAFile)
        selectedFile.lineBreakMode = .byTruncatingMiddle; selectedFile.textColor = .secondaryLabelColor
        extensionField.isEditable = true; extensionField.completes = true; extensionField.delegate = self
        extensionField.addItems(withObjectValues: FileTypeCatalog.common.map { $0.0 })
        appPicker.target = self; appPicker.action = #selector(updateActions)
        makeDefault.target = self; makeDefault.action = #selector(updateActions)
        fileRuleNote.textColor = .secondaryLabelColor; fileRuleNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        targetDetailsTable.delegate = self; targetDetailsTable.dataSource = self; targetDetailsTable.usesAlternatingRowBackgroundColors = true
        targetDetailsTable.headerView = NSTableHeaderView(); targetDetailsTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        [("Target Extension", "Extension", 150.0), ("Target Type Identifier", "macOS internal content-type identifier", 360.0)].forEach { identifier, title, width in
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier)); column.title = title; column.width = width; targetDetailsTable.addTableColumn(column)
        }
        systemProfiles.target = self; systemProfiles.action = #selector(systemProfileChanged)
        editingProfiles.target = self; editingProfiles.action = #selector(editingProfileChanged)
        viewingProfiles.target = self; viewingProfiles.action = #selector(viewingProfileChanged)
        save.target = self; save.action = #selector(saveOnly)
        saveOpen.target = self; saveOpen.action = #selector(saveAndOpen)
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        defaultsTable.delegate = self; defaultsTable.dataSource = self; defaultsTable.usesAlternatingRowBackgroundColors = true
        [("Extension", 92.0), ("File Type", 265.0), ("Default App", 235.0)].forEach { name, width in
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name)); column.title = name; column.width = width; defaultsTable.addTableColumn(column)
        }
        fileOverridesTable.delegate = self; fileOverridesTable.dataSource = self; fileOverridesTable.usesAlternatingRowBackgroundColors = true
        [("File", 210.0), ("Open With", 180.0), ("Path", 200.0)].forEach { name, width in
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Override " + name)); column.title = name; column.width = width; fileOverridesTable.addTableColumn(column)
        }
    }

    private func buildTabs() {
        let editor = NSViewController(); editor.title = "Set Default"; editor.view = editorView()
        let browser = NSViewController(); browser.title = "Current Defaults"; browser.view = defaultsView()
        let settings = NSViewController(); settings.title = "Settings"; settings.view = settingsView()
        let tabController = NSTabViewController(); tabController.tabStyle = .segmentedControlOnTop; tabController.addChild(editor); tabController.addChild(browser); tabController.addChild(settings)
        tabs = tabController
        tabController.tabView.drawsBackground = false
        addChild(tabController); tabController.view.translatesAutoresizingMaskIntoConstraints = false; tabController.view.wantsLayer = true; tabController.view.layer?.backgroundColor = .clear; view.addSubview(tabController.view)
        NSLayoutConstraint.activate([tabController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), tabController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), tabController.view.topAnchor.constraint(equalTo: view.topAnchor), tabController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
    }

    private func editorView() -> NSView {
        let content = TopAlignedView(); let targetRow = row(source, chooseFile, selectedFile, extensionField)
        let targetDetailsScroll = NSScrollView(); targetDetailsScroll.documentView = targetDetailsTable; targetDetailsScroll.hasVerticalScroller = false; targetDetailsScroll.borderType = .bezelBorder
        extensionField.widthAnchor.constraint(equalToConstant: 180).isActive = true; selectedFile.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        let systemProfileRow = row(systemProfiles, button("Manage…", #selector(manageProfiles)))
        systemProfiles.widthAnchor.constraint(equalToConstant: 260).isActive = true
        profileWriteHint.textColor = .secondaryLabelColor; profileWriteHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let editingProfileRow = row(editingProfiles, button("New Profile…", #selector(newProfileForEditing)))
        editingProfiles.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let actions = row(save, saveOpen); let line = divider()
        let stack = NSStackView(views: [heading("System Defaults Profile"), systemProfileRow, heading("Target"), targetRow, targetDetailsScroll, heading("Open With"), appPicker, makeDefault, fileRuleNote, line, heading("Save Setting to Profile"), editingProfileRow, profileWriteHint, status, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9; stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16), appPicker.widthAnchor.constraint(equalTo: stack.widthAnchor), targetDetailsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor), targetDetailsScroll.heightAnchor.constraint(equalToConstant: 48), line.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        return scrollable(content, minimumHeight: 480)
    }

    private func defaultsView() -> NSView {
        let content = TopAlignedView(); let note = NSTextField(wrappingLabelWithString: "This tab is read-only. It shows the rules stored in the selected profile.")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let scroll = NSScrollView(); scroll.documentView = defaultsTable; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let fileOverrideTitle = heading("Specific File Overrides (Experimental)")
        let fileOverrideNote = NSTextField(labelWithString: "Rules managed by this app. macOS has no public API to list rules created elsewhere.")
        fileOverrideNote.textColor = .secondaryLabelColor; fileOverrideNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let overrideScroll = NSScrollView(); overrideScroll.documentView = fileOverridesTable; overrideScroll.hasVerticalScroller = true; overrideScroll.borderType = .bezelBorder
        viewingProfiles.widthAnchor.constraint(equalToConstant: 280).isActive = true
        var views: [NSView] = [heading("Defaults Profile"), viewingProfiles, note, scroll]
        if AppSettings.current.experimentalFileOverrides { views += [fileOverrideTitle, fileOverrideNote, overrideScroll] }
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        var constraints = [stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)]
        if AppSettings.current.experimentalFileOverrides { constraints += [overrideScroll.widthAnchor.constraint(equalTo: stack.widthAnchor), overrideScroll.heightAnchor.constraint(equalToConstant: 125)] }
        NSLayoutConstraint.activate(constraints)
        return scrollable(content, minimumHeight: 500)
    }

    private func settingsView() -> NSView {
        let content = TopAlignedView()
        var configuredSettings = AppSettings.current
        let themePicker = NSPopUpButton(frame: .zero, pullsDown: false)
        themePicker.addItems(withTitles: ["System", "Light", "Dark"])
        themePicker.selectItem(withTitle: configuredSettings.theme == .system ? "System" : configuredSettings.theme == .light ? "Light" : "Dark")
        themePicker.target = self; themePicker.action = #selector(themeChanged(_:))
        let backgroundPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        backgroundPicker.addItems(withTitles: ["Opaque", "Transparent"])
        backgroundPicker.selectItem(withTitle: configuredSettings.windowBackground == .opaque ? "Opaque" : "Transparent")
        backgroundPicker.target = self; backgroundPicker.action = #selector(windowBackgroundChanged(_:))
        themePicker.widthAnchor.constraint(equalToConstant: 150).isActive = true; backgroundPicker.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let appearanceTitle = heading("Appearance")
        let themeRow = row(NSTextField(labelWithString: "Theme"), themePicker)
        let backgroundRow = row(NSTextField(labelWithString: "Window Background"), backgroundPicker)
        let openFinderExtensions = button("Manage Finder Extensions…", #selector(openFinderExtensionsSettings))
        let menuBarToggle = NSButton(checkboxWithTitle: "Keep running in the menu bar after closing or pressing Command-Q", target: self, action: #selector(menuBarRunningChanged(_:)))
        menuBarToggle.state = configuredSettings.keepRunningInMenuBar ? .on : .off
        keepRunningToggle = menuBarToggle
        let enableAtLogin = button("Open at Login", #selector(enableOpenAtLogin))
        let sourceNote = NSTextField(wrappingLabelWithString: "To remove this Finder menu, choose Manage Finder Extensions… and turn off \(AppIdentity.displayName).")
        sourceNote.textColor = .secondaryLabelColor; sourceNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let loginNote = NSTextField(wrappingLabelWithString: "Open at Login enables \(AppIdentity.displayName) for this account and opens Login Items so you can review it. Requires macOS 13 or later.")
        loginNote.textColor = .secondaryLabelColor; loginNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let directory = NSTextField(labelWithString: AppSettings.profilesDirectory.path)
        directory.lineBreakMode = .byTruncatingMiddle; directory.textColor = .secondaryLabelColor
        let changeFolder = button("Change…", #selector(changeProfilesFolder))
        let finderTitle = heading("Finder Integration")
        let backgroundTitle = heading("Background Activity")
        let profileStorageTitle = heading("Profile Storage")
        let baselineTitle = heading("Apple Defaults Profile")
        let baselineNote = NSTextField(wrappingLabelWithString: "This protected profile is a snapshot of Launch Services’ current defaults for the app’s catalog when the profile folder is first created. macOS does not expose a factory-default reset or a complete association list.")
        baselineNote.textColor = .secondaryLabelColor; baselineNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let experimentalToggle = NSButton(checkboxWithTitle: "Enable file-specific defaults (Experimental)", target: self, action: #selector(fileOverridesExperimentChanged(_:)))
        experimentalToggle.state = configuredSettings.experimentalFileOverrides ? .on : .off
        let folderRow = row(directory, changeFolder)
        let stack = NSStackView(views: [appearanceTitle, themeRow, backgroundRow, divider(), finderTitle, sourceNote, openFinderExtensions, divider(), backgroundTitle, menuBarToggle, enableAtLogin, loginNote, divider(), profileStorageTitle, folderRow, divider(), baselineTitle, baselineNote, divider(), experimentalToggle])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18), directory.widthAnchor.constraint(greaterThanOrEqualToConstant: 380)])
        return scrollable(content, minimumHeight: 480)
    }

    func showSettings() { tabs?.selectedTabViewItemIndex = 2 }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        var settings = AppSettings.current
        settings.theme = ["System": .system, "Light": .light, "Dark": .dark][sender.titleOfSelectedItem ?? "System"] ?? .system
        AppSettings.save(settings)
    }

    @objc private func windowBackgroundChanged(_ sender: NSPopUpButton) {
        var settings = AppSettings.current
        settings.windowBackground = sender.titleOfSelectedItem == "Transparent" ? .transparent : .opaque
        AppSettings.save(settings)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyWindowAppearance()
    }

    func applyWindowAppearance() {
        guard isViewLoaded else { return }
        let settings = AppSettings.current
        let transparent = settings.windowBackground == .transparent
        let appearance: NSAppearance?
        switch settings.theme {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        view.window?.appearance = appearance
        view.appearance = appearance
        tabs?.view.appearance = appearance
        windowBackground.appearance = appearance
        view.window?.isOpaque = !transparent
        view.window?.backgroundColor = transparent ? .clear : .windowBackgroundColor
        windowBackground.isHidden = false
        windowBackground.material = transparent ? .underWindowBackground : .windowBackground
        windowBackground.blendingMode = transparent ? .behindWindow : .withinWindow
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    @objc private func openFinderExtensionsSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    @objc private func enableOpenAtLogin() {
        guard #available(macOS 13.0, *) else {
            let alert = NSAlert(); alert.messageText = "Open at Login requires macOS 13 or later"; alert.informativeText = "This app’s supported login-item implementation is available in macOS Ventura and later."; alert.alertStyle = .informational; alert.runModal()
            return
        }
        do {
            try SMAppService.mainApp.register()
            SMAppService.openSystemSettingsLoginItems()
        } catch {
            let alert = NSAlert(error: error); alert.messageText = "Couldn’t enable Open at Login"; alert.runModal()
        }
    }

    @objc private func menuBarRunningChanged(_ sender: NSButton) {
        var settings = AppSettings.current
        settings.keepRunningInMenuBar = sender.state == .on
        AppSettings.save(settings)
    }

    @objc private func fileOverridesExperimentChanged(_ sender: NSButton) {
        var settings = AppSettings.current
        settings.experimentalFileOverrides = sender.state == .on
        AppSettings.save(settings)
        updateFileOverrideExperimentUI()
        reloadProfiles(); refreshDefaults()
        tabs?.children[1].view = defaultsView()
    }

    private func updateFileOverrideExperimentUI() {
        let enabled = AppSettings.current.experimentalFileOverrides
        source.setLabel("File (Experimental)", forSegment: 0)
        source.setEnabled(enabled, forSegment: 0)
        if !enabled, mode == .file {
            source.selectedSegment = 1
            sourceChanged()
        }
    }

    @objc private func changeProfilesFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        AppSettings.setProfilesDirectory(directory)
        store = DefaultsProfileStore()
        reloadProfiles(); refreshDefaults()
        tabs?.children[2].view = settingsView()
    }

    private func heading(_ text: String) -> NSTextField { let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold); return label }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func row(_ views: NSView...) -> NSStackView { let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 8; return stack }
    private func divider() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }

    private func scrollable(_ content: NSView, minimumHeight: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.hasHorizontalScroller = false
        content.frame = NSRect(x: 0, y: 0, width: 640, height: minimumHeight)
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.widthAnchor.constraint(equalTo: clip.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight)
        ])
        return scroll
    }

    @objc private func sourceChanged() {
        mode = source.selectedSegment == 0 ? .file : .fileExtension; let isFile = mode == .file
        chooseFile.isHidden = !isFile; selectedFile.isHidden = !isFile; extensionField.isHidden = isFile
        fileRuleNote.isHidden = !isFile
        if !isFile { selectExtension(extensionField.stringValue.isEmpty ? fileExtension : extensionField.stringValue) }
        updateActions()
    }

    @objc private func chooseAFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.prompt = "Use File"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectFile(url: url)
    }

    func selectFile(url: URL) {
        let fileOverridesEnabled = AppSettings.current.experimentalFileOverrides
        source.selectedSegment = fileOverridesEnabled ? 0 : 1
        mode = fileOverridesEnabled ? .file : .fileExtension
        chooseFile.isHidden = !fileOverridesEnabled; selectedFile.isHidden = !fileOverridesEnabled; extensionField.isHidden = fileOverridesEnabled
        fileURL = url; fileExtension = url.pathExtension.lowercased(); typeID = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier
        selectedFile.stringValue = url.path; extensionField.stringValue = fileExtension; apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        targetDetailsTable.reloadData(); reloadApps(); makeDefault.state = .off; updateActions()
    }

    func handleFinderSelection(fileURL: URL, applicationBundleIdentifier: String) {
        selectFile(url: fileURL)
        guard let index = apps.firstIndex(where: { Bundle(url: $0)?.bundleIdentifier == applicationBundleIdentifier }) else {
            status.stringValue = "The selected application is no longer available."
            return
        }
        appPicker.selectItem(at: index)
        let activeProfile = store.activeProfile
        let profileDefault = (AppSettings.current.experimentalFileOverrides
            ? activeProfile.fileOverrides?.first(where: { $0.filePath == fileURL.path })?.applicationBundleIdentifier
            : nil)
            ?? activeProfile.associations.first(where: { $0.fileExtension.caseInsensitiveCompare(fileURL.pathExtension) == .orderedSame })?.applicationBundleIdentifier
            ?? NSWorkspace.shared.urlForApplication(toOpen: fileURL).flatMap { Bundle(url: $0)?.bundleIdentifier }
        if profileDefault == applicationBundleIdentifier {
            openSelectedFile()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.presentFinderChoice()
        }
    }

    private func presentFinderChoice() {
        guard let fileURL, let application = appPicker.selectedItem?.representedObject as? URL else { return }
        let applicationName = FileManager.default.displayName(atPath: application.path)
        let alert = NSAlert()
        alert.messageText = "Make \(applicationName) the default?"
        let fileOverridesEnabled = AppSettings.current.experimentalFileOverrides
        alert.informativeText = fileOverridesEnabled
            ? "Choose whether \(applicationName) should open just this time, \(fileURL.lastPathComponent) only, or every .\(fileExtension) file."
            : "Choose whether \(applicationName) should open just this time or every .\(fileExtension) file."
        alert.addButton(withTitle: "Open Only This Time")
        if fileOverridesEnabled { alert.addButton(withTitle: "For This File") }
        alert.addButton(withTitle: "For All .\(fileExtension) Files")
        alert.addButton(withTitle: "Cancel")
        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.openSelectedFile()
            } else if fileOverridesEnabled, response == .alertSecondButtonReturn {
                self.saveFinderChoice(scope: .file)
            } else if response == (fileOverridesEnabled ? .alertThirdButtonReturn : .alertSecondButtonReturn) {
                self.saveFinderChoice(scope: .allFiles)
            }
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: handleResponse) }
        else { handleResponse(alert.runModal()) }
    }

    private enum FinderScope { case file, allFiles }

    private func saveFinderChoice(scope: FinderScope) {
        guard let association = selectedAssociation() else { return }
        var profile = store.activeProfile
        if profile.isAppleBaseline { profile = store.createProfile(named: "Custom Defaults", copying: profile) }
        if scope == .allFiles {
            if let index = profile.associations.firstIndex(where: { $0.typeIdentifier == association.typeIdentifier }) {
                profile.associations[index] = association
            } else {
                profile.associations.append(association)
            }
        }

        var fileOverride: FileOverride?
        if scope == .file, let fileURL, let application = appPicker.selectedItem?.representedObject as? URL,
           let bundleIdentifier = Bundle(url: application)?.bundleIdentifier {
            let override = FileOverride(id: UUID(), filePath: fileURL.path, displayName: fileURL.lastPathComponent, applicationBundleIdentifier: bundleIdentifier)
            var overrides = profile.fileOverrides ?? []
            if let index = overrides.firstIndex(where: { $0.filePath == fileURL.path }) { overrides[index] = override } else { overrides.append(override) }
            profile.fileOverrides = overrides
            fileOverride = override
        }
        store.save(profile); reloadProfiles(); selectProfile(profile.id, in: editingProfiles); selectProfile(profile.id, in: viewingProfiles)

        if let fileOverride, let fileURL {
            guard removeQuarantineWithNotice(from: fileURL) == nil else {
                status.stringValue = "Saved to \(profile.name), but the Finder rule was not applied."
                refreshDefaults()
                return
            }
            apply(fileOverride) { [weak self] error in
                self?.status.stringValue = error.map { "Couldn’t apply file rule: \($0.localizedDescription)" } ?? "Saved to \(profile.name) and made \(fileOverride.displayName) open with the selected app."
                self?.refreshDefaults()
                if error == nil { self?.openSelectedFile() }
            }
        } else {
            apply(association) { [weak self] error in
                self?.status.stringValue = error.map { "Couldn’t apply default: \($0.localizedDescription)" } ?? "Saved to \(profile.name) and made the selected app the default for .\(association.fileExtension) files."
                self?.refreshDefaults()
                if error == nil { self?.openSelectedFile() }
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) { if mode == .fileExtension { selectExtension(extensionField.stringValue) } }
    private func selectExtension(_ value: String) {
        let ext = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased(); guard !ext.isEmpty else { return }
        fileExtension = ext; extensionField.stringValue = ext; typeID = FileTypeCatalog.typeIdentifier(for: ext)
        targetDetailsTable.reloadData()
        apps = typeID.flatMap { UTType($0) }.map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []; reloadApps(); updateActions()
    }

    private func reloadApps() {
        appPicker.removeAllItems(); apps.forEach { url in appPicker.addItem(withTitle: FileManager.default.displayName(atPath: url.path)); appPicker.lastItem?.representedObject = url }
        if apps.isEmpty { appPicker.addItem(withTitle: "No compatible applications found") }
        if let id = typeID, let type = UTType(id), let current = NSWorkspace.shared.urlForApplication(toOpen: type), let index = apps.firstIndex(where: { $0.standardizedFileURL == current.standardizedFileURL }) { appPicker.selectItem(at: index) }
    }

    @objc private func updateActions() {
        let extensionMode = mode == .fileExtension; makeDefault.state = extensionMode ? .on : makeDefault.state; makeDefault.isEnabled = !extensionMode
        makeDefault.title = "Make this the system default for all .\(fileExtension) files"
        let valid = typeID != nil && (appPicker.selectedItem?.representedObject as? URL) != nil; save.isEnabled = valid; saveOpen.isEnabled = valid && !extensionMode && fileURL != nil
    }

    private func selectedAssociation() -> DefaultAssociation? {
        guard let typeID, let app = appPicker.selectedItem?.representedObject as? URL, let bundleID = Bundle(url: app)?.bundleIdentifier else { return nil }
        let name = FileTypeCatalog.common.first(where: { $0.0 == fileExtension })?.1 ?? ".\(fileExtension) file"
        return DefaultAssociation(fileExtension: fileExtension, displayName: name, typeIdentifier: typeID, applicationBundleIdentifier: bundleID)
    }

    @objc private func saveOnly() { saveSelection(open: false) }
    @objc private func saveAndOpen() { saveSelection(open: true) }
    private func saveSelection(open: Bool) {
        guard let association = selectedAssociation() else { return }; var profile = editingProfile
        let openingFile = fileURL
        if profile.isAppleBaseline { profile = store.createProfile(named: "Custom Defaults", copying: profile); reloadProfiles() }
        let savesSystemDefault = mode == .fileExtension || makeDefault.state == .on
        if savesSystemDefault {
            if let i = profile.associations.firstIndex(where: { $0.typeIdentifier == association.typeIdentifier }) {
                profile.associations[i] = association
            } else {
                profile.associations.append(association)
            }
        }
        var fileOverride: FileOverride?
        if mode == .file, let fileURL, let app = appPicker.selectedItem?.representedObject as? URL, let bundleID = Bundle(url: app)?.bundleIdentifier {
            let override = FileOverride(id: UUID(), filePath: fileURL.path, displayName: fileURL.lastPathComponent, applicationBundleIdentifier: bundleID)
            var overrides = profile.fileOverrides ?? []
            if let index = overrides.firstIndex(where: { $0.filePath == fileURL.path }) { overrides[index] = override } else { overrides.append(override) }
            profile.fileOverrides = overrides
            fileOverride = override
        }
        store.save(profile); reloadProfiles(); selectProfile(profile.id, in: editingProfiles)
        let finish: (Error?, String) -> Void = { [weak self] error, message in
            self?.status.stringValue = error.map { "Couldn’t save rule: \($0.localizedDescription)" } ?? message
                self?.refreshDefaults()
            if error == nil, open, let openingFile {
                self?.openWithDefaultApplication(file: openingFile)
            }
        }
        if let fileOverride {
            guard let fileURL, removeQuarantineWithNotice(from: fileURL) == nil else {
                status.stringValue = "Saved to \(profile.name), but the file-only Finder rule was not applied."
                refreshDefaults()
                return
            }
            apply(fileOverride) { [weak self] fileError in
                guard let self else { return }
                if fileError != nil { finish(fileError, "") }
                else if self.makeDefault.state == .on {
                    self.apply(association) { typeError in finish(typeError, "Saved to \(profile.name), applied this file rule, and made it the system default.") }
                } else {
                    finish(nil, "Saved to \(profile.name) and applied this file rule only.")
                }
            }
        } else {
            apply(association) { error in finish(error, "Saved to \(profile.name) and applied the system default.") }
        }
    }

    private func openSelectedFile() {
        guard let file = fileURL, let app = appPicker.selectedItem?.representedObject as? URL else { return }
        open(file: file, with: app)
    }

    private func open(file: URL, with application: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: application, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.status.stringValue = "Saved, but couldn’t open the file: \(error.localizedDescription)"
            }
        }
    }

    /// Resolve the handler after saving so Save & Open follows the default that
    /// Launch Services has just applied, rather than a previously captured picker value.
    private func openWithDefaultApplication(file: URL) {
        guard let application = NSWorkspace.shared.urlForApplication(toOpen: file) else {
            status.stringValue = "Saved, but macOS could not find a default application to open the file."
            return
        }
        open(file: file, with: application)
    }

    private func removeQuarantineWithNotice(from url: URL) -> Error? {
        let alert = NSAlert()
        alert.messageText = "Remove download quarantine before applying the file rule?"
        alert.informativeText = "This required step removes macOS’s quarantine marker from \(url.lastPathComponent). It allows the chosen app to open the file without Gatekeeper treating it as an unverified download. Only continue if you trust the file and its source."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove Quarantine & Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return NSError(domain: "BetterOpenWith", code: 3, userInfo: [NSLocalizedDescriptionKey: "Quarantine removal was cancelled."]) }
        let result = removexattr(url.path, "com.apple.quarantine", 0)
        if result == 0 || errno == ENOATTR { return nil }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "macOS could not remove the quarantine marker."])
    }

    private func apply(_ association: DefaultAssociation, completion: @escaping (Error?) -> Void) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: association.applicationBundleIdentifier), let type = UTType(association.typeIdentifier) else { completion(NSError(domain: "BetterOpenWith", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected app is not installed."])); return }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    private func apply(_ override: FileOverride, completion: @escaping (Error?) -> Void) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: override.applicationBundleIdentifier) else {
            completion(NSError(domain: "BetterOpenWith", code: 2, userInfo: [NSLocalizedDescriptionKey: "The selected app is not installed."]))
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenFileAt: URL(fileURLWithPath: override.filePath)) { error in
            let verificationError: Error?
            if let error {
                verificationError = error
            } else {
                let appliedApplication = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: override.filePath))
                let appliedBundleIdentifier = appliedApplication.flatMap { Bundle(url: $0)?.bundleIdentifier }
                verificationError = appliedBundleIdentifier == override.applicationBundleIdentifier ? nil : NSError(
                    domain: "BetterOpenWith",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "macOS did not confirm the file-specific default. The file still resolves to \(appliedApplication.map { FileManager.default.displayName(atPath: $0.path) } ?? "no application")."]
                )
            }
            DispatchQueue.main.async { completion(verificationError) }
        }
    }

    private func profileSelected(in popup: NSPopUpButton) -> DefaultsProfile? {
        guard let raw = popup.selectedItem?.representedObject as? String, let id = UUID(uuidString: raw) else { return nil }
        return store.profiles.first(where: { $0.id == id })
    }

    private var editingProfile: DefaultsProfile { profileSelected(in: editingProfiles) ?? store.activeProfile }
    private var viewingProfile: DefaultsProfile { profileSelected(in: viewingProfiles) ?? store.activeProfile }

    private func reloadProfiles() {
        let active = store.activeProfile
        AppSettings.publishFinderProfile(active)
        let editingID = profileSelected(in: editingProfiles)?.id ?? active.id
        let viewingID = profileSelected(in: viewingProfiles)?.id ?? active.id
        [systemProfiles, editingProfiles, viewingProfiles].forEach { popup in
            popup.removeAllItems()
            for profile in store.profiles { popup.addItem(withTitle: profile.name); popup.lastItem?.representedObject = profile.id.uuidString }
        }
        selectProfile(active.id, in: systemProfiles)
        selectProfile(store.profiles.contains(where: { $0.id == editingID }) ? editingID : active.id, in: editingProfiles)
        selectProfile(store.profiles.contains(where: { $0.id == viewingID }) ? viewingID : active.id, in: viewingProfiles)
        updateProfileWriteHint()
    }

    private func selectProfile(_ id: UUID, in popup: NSPopUpButton) {
        if let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == id.uuidString }) { popup.selectItem(at: index) }
    }

    @objc private func systemProfileChanged() {
        guard let profile = profileSelected(in: systemProfiles) else { return }
        store.activate(profile)
        selectProfile(profile.id, in: editingProfiles)
        applyProfile()
    }

    @objc private func editingProfileChanged() { updateProfileWriteHint() }
    @objc private func viewingProfileChanged() { refreshDefaults() }

    private func updateProfileWriteHint() {
        let profile = editingProfile
        if profile.isAppleBaseline {
            profileWriteHint.stringValue = "Apple Defaults is protected. Save will create and write to \(store.nextDefaultProfileName())."
        } else {
            profileWriteHint.stringValue = "New settings will be written to \(profile.name)."
        }
    }

    @objc private func newProfileForEditing() {
        let alert = NSAlert(); alert.messageText = "New Defaults Profile"; alert.informativeText = "The new profile starts as a copy of the selected edit profile."
        let field = NSTextField(string: store.nextDefaultProfileName()); field.frame.size = NSSize(width: 260, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if name != store.nextDefaultProfileName(), store.hasProfile(named: name) {
            let duplicate = NSAlert(); duplicate.messageText = "Profile name already in use"; duplicate.informativeText = "Choose a different name for this defaults profile."; duplicate.alertStyle = .warning; duplicate.runModal()
            return
        }
        let newProfile = store.createProfile(named: name, copying: editingProfile)
        reloadProfiles(); selectProfile(newProfile.id, in: editingProfiles); updateProfileWriteHint()
    }

    @objc private func manageProfiles() { let controller = ProfileManagerViewController(store: store) { [weak self] in self?.reloadProfiles(); self?.refreshDefaults() }; let window = NSWindow(contentViewController: controller); window.title = "Manage Defaults Profiles"; window.styleMask = [.titled, .closable]; window.setContentSize(NSSize(width: 390, height: 270)); profileWindow = NSWindowController(window: window); profileWindow?.showWindow(self) }

    private func refreshDefaults() {
        let profile = viewingProfile
        currentDefaults = profile.associations.sorted { $0.fileExtension < $1.fileExtension }
        fileOverrides = (profile.fileOverrides ?? []).sorted { $0.displayName < $1.displayName }
        defaultsTable.reloadData(); fileOverridesTable.reloadData()
    }
    @objc private func applyProfile() {
        let profile = store.activeProfile; let group = DispatchGroup(); var failures = [String]()
        for item in profile.associations { group.enter(); apply(item) { error in if error != nil { failures.append(item.fileExtension) }; group.leave() } }
        if AppSettings.current.experimentalFileOverrides {
            for item in profile.fileOverrides ?? [] { group.enter(); apply(item) { error in if error != nil { failures.append(item.displayName) }; group.leave() } }
        }
        group.notify(queue: .main) { [weak self] in self?.status.stringValue = failures.isEmpty ? "Applied \(profile.name)." : "Some rules could not be applied: \(failures.joined(separator: ", "))."; self?.refreshDefaults() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == targetDetailsTable { return fileExtension.isEmpty ? 0 : 1 }
        return tableView == defaultsTable ? currentDefaults.count : fileOverrides.count
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == targetDetailsTable {
            let text = tableColumn?.identifier.rawValue == "Target Extension" ? ".\(fileExtension)" : (typeID ?? "Type unavailable")
            return NSTextField(labelWithString: text)
        }
        if tableView == fileOverridesTable {
            let item = fileOverrides[row]; let text: String
            switch tableColumn?.identifier.rawValue {
            case "Override File": text = item.displayName
            case "Override Open With": text = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.applicationBundleIdentifier)?.deletingPathExtension().lastPathComponent ?? item.applicationBundleIdentifier
            default: text = item.filePath
            }
            return NSTextField(labelWithString: text)
        }
        let item = currentDefaults[row]; let text: String
        switch tableColumn?.identifier.rawValue { case "Extension": text = ".\(item.fileExtension)"; case "File Type": text = item.displayName; default: text = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.applicationBundleIdentifier)?.deletingPathExtension().lastPathComponent ?? item.applicationBundleIdentifier }
        return NSTextField(labelWithString: text)
    }
}

private final class TopAlignedView: NSView {
    override var isFlipped: Bool { true }
}

private final class ProfileManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: DefaultsProfileStore; private let didChange: () -> Void; private let table = NSTableView()
    private var profiles: [DefaultsProfile] { store.profiles }
    init(store: DefaultsProfileStore, didChange: @escaping () -> Void) { self.store = store; self.didChange = didChange; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() { view = NSView() }
    override func viewDidLoad() { super.viewDidLoad(); table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = true; let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Profile")); column.title = "Profile"; table.addTableColumn(column); let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; let hint = NSTextField(wrappingLabelWithString: "Select one or more custom profiles to delete. Apple Defaults is protected."); hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize); let delete = NSButton(title: "Delete Selected…", target: self, action: #selector(deleteProfile)); let stack = NSStackView(views: [scroll, hint, delete]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)]) }
    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { let item = profiles[row]; return NSTextField(labelWithString: item.isAppleBaseline ? "\(item.name)  (protected)" : item.name) }
    @objc private func deleteProfile() {
        let selected = table.selectedRowIndexes.compactMap { profiles.indices.contains($0) ? profiles[$0] : nil }.filter { !$0.isAppleBaseline }
        guard !selected.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "Delete \(selected.count) profile\(selected.count == 1 ? "" : "s")?"; alert.informativeText = "This removes the selected custom defaults profiles. This cannot be undone."; alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        selected.forEach { store.delete($0) }
        table.reloadData(); didChange()
    }
}
