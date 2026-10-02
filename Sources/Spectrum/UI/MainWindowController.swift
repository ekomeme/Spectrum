import AppKit
import AVFoundation

/// Settings-style main window: a preference toolbar with two big tabs (Plugin Chain, Audio Settings)
/// and a shared bottom bar with meters, status and Start/Stop.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let engine: AudioEngineController
    /// Called when the user closes the window; the app decides what to do (hide to the menu bar).
    var onHide: (() -> Void)?

    enum Tab: String, CaseIterable {
        case pluginChain, audioSettings

        var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }
        var label: String { self == .pluginChain ? "Plugin Chain" : "Audio Settings" }
        var symbol: String { self == .pluginChain ? "slider.horizontal.3" : "speaker.wave.2" }
    }

    private var currentTab: Tab = .pluginChain
    private let tabContainer = NSView()
    private var pluginChainView: NSView!
    private var audioSettingsView: NSView!

    // Audio settings controls
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let outputPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bufferPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let muteSwitch = NSSwitch()

    // Plugin chain controls
    private let pluginStack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No plugins yet. Click “Add Plugin…” to load one, for example FabFilter Pro-Q 4.")

    // Shared bottom bar
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let meterLeft = NSLevelIndicator()
    private let meterRight = NSLevelIndicator()
    private let startButton = NSButton(title: "Start", target: nil, action: nil)

    private var pickerController: PluginPickerController?
    private var devices: [AudioDevice] = []

    init(engine: AudioEngineController) {
        self.engine = engine
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = Tab.pluginChain.label
        window.center()
        window.setFrameAutosaveName("SpectrumMainWindow")
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "SpectrumToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = Tab.pluginChain.identifier
        window.toolbar = toolbar

        pluginChainView = buildPluginChainView()
        audioSettingsView = buildAudioSettingsView()
        buildUI()
        showTab(.pluginChain, animated: false)

        engine.onStateChange = { [weak self] in self?.refresh() }
        engine.onLevel = { [weak self] left, right in self?.updateMeters(left, right) }
        AudioDeviceManager.shared.addObserver { [weak self] in self?.refreshDevices() }
        refreshDevices()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let onHide {
            onHide()
            return false
        }
        return true
    }

    /// Diagnostics only.
    func selectTabForSnapshot(_ tab: Tab) { showTab(tab, animated: false) }

    // MARK: - Toolbar (tabs)

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.identifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = Tab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.label
        item.paletteLabel = tab.label
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
        item.target = self
        item.action = #selector(tabSelected(_:))
        return item
    }

    @objc private func tabSelected(_ sender: NSToolbarItem) {
        guard let tab = Tab(rawValue: sender.itemIdentifier.rawValue) else { return }
        showTab(tab, animated: true)
    }

    private func showTab(_ tab: Tab, animated: Bool) {
        currentTab = tab
        window?.title = tab.label
        window?.toolbar?.selectedItemIdentifier = tab.identifier
        for view in tabContainer.subviews { view.removeFromSuperview() }
        let view: NSView = tab == .pluginChain ? pluginChainView : audioSettingsView
        view.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: tabContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
        ])
        fitWindowToContent(animated: animated)
    }

    /// Settings-style windows resize to fit the selected pane.
    private func fitWindowToContent(animated: Bool) {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let target = content.fittingSize
        var frame = window.frame
        let newFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 620, height: target.height))
        let delta = newFrame.height - frame.height
        frame.origin.y -= delta
        frame.size = NSSize(width: newFrame.width, height: newFrame.height)
        window.setFrame(frame, display: true, animate: animated)
    }

    // MARK: - Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }

        tabContainer.translatesAutoresizingMaskIntoConstraints = false

        for meter in [meterLeft, meterRight] {
            meter.levelIndicatorStyle = .continuousCapacity
            meter.minValue = 0
            meter.maxValue = 1
            meter.warningValue = 0.8
            meter.criticalValue = 0.97
            meter.doubleValue = 0
            meter.heightAnchor.constraint(equalToConstant: 8).isActive = true
            meter.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        let meters = NSStackView(views: [meterLeft, meterRight])
        meters.orientation = .vertical
        meters.spacing = 3
        meters.alignment = .leading

        startButton.target = self
        startButton.action = #selector(toggleEngine)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.controlSize = .large

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bottom = NSStackView(views: [meters, statusLabel, startButton])
        bottom.orientation = .horizontal
        bottom.distribution = .fill
        bottom.alignment = .centerY
        statusLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        bottom.spacing = 14

        let root = NSStackView(views: [tabContainer, separator(), bottom])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            tabContainer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            bottom.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
        ])
        for sep in root.arrangedSubviews where sep is NSBox {
            sep.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        }
    }

    /// Plugin Chain tab: "Add Plugin…" button and the grouped list of loaded plugins.
    private func buildPluginChainView() -> NSView {
        let title = NSTextField(labelWithString: "Plugins run in order, top to bottom.")
        title.textColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 12)
        let addButton = NSButton(title: "Add Plugin…", target: self, action: #selector(addPlugin))
        addButton.bezelStyle = .rounded
        title.setContentHuggingPriority(.init(1), for: .horizontal)
        let headerRow = NSStackView(views: [title, addButton])
        headerRow.orientation = .horizontal
        headerRow.distribution = .fill
        headerRow.alignment = .centerY

        pluginStack.orientation = .vertical
        pluginStack.alignment = .leading
        pluginStack.spacing = 0
        emptyLabel.textColor = .secondaryLabelColor

        let group = GroupBoxView()
        let flipped = FlippedClipDocument()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        pluginStack.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(pluginStack)
        let scroll = NSScrollView()
        scroll.documentView = flipped
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        group.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: group.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: group.bottomAnchor),
            pluginStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            pluginStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            pluginStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            pluginStack.bottomAnchor.constraint(lessThanOrEqualTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            flipped.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])

        let stack = NSStackView(views: [headerRow, group])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            group.widthAnchor.constraint(equalTo: stack.widthAnchor),
            group.heightAnchor.constraint(equalToConstant: 300),
        ])
        return stack
    }

    /// Audio Settings tab: grouped form with source, output, buffer size and the mute switch.
    private func buildAudioSettingsView() -> NSView {
        sourcePopup.target = self; sourcePopup.action = #selector(sourceChanged)
        outputPopup.target = self; outputPopup.action = #selector(outputChanged)
        bufferPopup.target = self; bufferPopup.action = #selector(bufferChanged)
        for size in [64, 128, 256, 512, 1024] {
            bufferPopup.addItem(withTitle: "\(size) frames")
            bufferPopup.lastItem?.tag = size
        }
        muteSwitch.target = self; muteSwitch.action = #selector(muteChanged)
        for popup in [sourcePopup, outputPopup, bufferPopup] {
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        }

        let routing = GroupBoxView()
        routing.addRows([
            FormRow(title: "Source", subtitle: "What Spectrum listens to", control: sourcePopup),
            FormRow(title: "Output", subtitle: "Where the processed audio plays", control: outputPopup),
            FormRow(title: "Buffer size", subtitle: "Smaller is lower latency, higher CPU", control: bufferPopup),
        ])
        let behaviour = GroupBoxView()
        behaviour.addRows([
            FormRow(title: "Mute original audio", subtitle: "Only hear the signal processed by Spectrum", control: muteSwitch),
        ])

        let stack = NSStackView(views: [sectionTitle("Routing"), routing, sectionTitle("System audio"), behaviour])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: routing)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            routing.widthAnchor.constraint(equalTo: stack.widthAnchor),
            behaviour.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: - Devices

    private func refreshDevices() {
        devices = AudioDeviceManager.shared.allDevices()

        sourcePopup.removeAllItems()
        sourcePopup.addItem(withTitle: "System audio (all apps)")
        sourcePopup.lastItem?.representedObject = nil
        sourcePopup.menu?.addItem(.separator())
        for device in devices where device.hasInput {
            sourcePopup.addItem(withTitle: "\(device.name) (\(device.inputChannels) ch)")
            sourcePopup.lastItem?.representedObject = device.uid
        }
        if let uid = engine.settings.sourceDeviceUID,
           let index = sourcePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == uid }) {
            sourcePopup.selectItem(at: index)
        } else {
            sourcePopup.selectItem(at: 0)
        }

        outputPopup.removeAllItems()
        let defaultOutput = AudioDeviceManager.shared.defaultOutputDeviceID()
        for device in devices where device.hasOutput {
            let suffix = device.id == defaultOutput ? " · default" : ""
            outputPopup.addItem(withTitle: device.name + suffix)
            outputPopup.lastItem?.representedObject = device.uid
        }
        if let uid = engine.settings.outputDeviceUID,
           let index = outputPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == uid }) {
            outputPopup.selectItem(at: index)
        } else if let index = outputPopup.itemArray.firstIndex(where: { $0.title.hasSuffix("default") }) {
            outputPopup.selectItem(at: index)
        }

        bufferPopup.selectItem(withTag: Int(engine.settings.bufferSize))
        if bufferPopup.selectedItem == nil { bufferPopup.selectItem(withTag: 256) }
        muteSwitch.state = engine.settings.muteOriginal ? .on : .off
        muteSwitch.isEnabled = engine.settings.sourceDeviceUID == nil
    }

    // MARK: - Refresh

    func refresh() {
        startButton.title = engine.isRunning ? "Stop" : "Start"
        if let error = engine.lastError {
            statusLabel.stringValue = "⚠️ \(error)"
            statusLabel.textColor = .systemRed
        } else if engine.isRunning {
            statusLabel.stringValue = "● Running · \(engine.statusDetail)"
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = "○ Stopped"
            statusLabel.textColor = .secondaryLabelColor
        }
        rebuildPluginRows()
    }

    private func rebuildPluginRows() {
        for view in pluginStack.arrangedSubviews {
            pluginStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if engine.slots.isEmpty {
            let padding = NSStackView(views: [emptyLabel])
            padding.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
            pluginStack.addArrangedSubview(padding)
            padding.widthAnchor.constraint(equalTo: pluginStack.widthAnchor).isActive = true
            return
        }
        for (index, slot) in engine.slots.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                pluginStack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: pluginStack.widthAnchor, constant: -28).isActive = true
            }
            let view = row(for: slot, index: index)
            pluginStack.addArrangedSubview(view)
            // Constrain only once both views share a superview, otherwise AppKit throws.
            view.widthAnchor.constraint(equalTo: pluginStack.widthAnchor).isActive = true
        }
    }

    private func row(for slot: PluginSlot, index: Int) -> NSView {
        let number = NSTextField(labelWithString: "\(index + 1)")
        number.textColor = .tertiaryLabelColor
        number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        number.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let name = NSTextField(labelWithString: slot.name)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        let maker = NSTextField(labelWithString: slot.supportsStereo ? slot.manufacturer : "\(slot.manufacturer) · stereo not supported, skipped")
        maker.font = .systemFont(ofSize: 11)
        maker.textColor = slot.supportsStereo ? .secondaryLabelColor : .systemOrange
        let names = NSStackView(views: [name, maker])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        names.setContentHuggingPriority(.init(1), for: .horizontal)
        names.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let editor = NSButton(title: "Editor", target: self, action: #selector(openPluginUI(_:)))
        editor.tag = index
        editor.bezelStyle = .rounded
        let bypass = NSButton(checkboxWithTitle: "Bypass", target: self, action: #selector(toggleBypass(_:)))
        bypass.tag = index
        bypass.state = slot.bypassed ? .on : .off
        let up = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Move up")!, target: self, action: #selector(movePluginUp(_:)))
        up.tag = index
        up.bezelStyle = .rounded
        up.isEnabled = index > 0
        let down = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Move down")!, target: self, action: #selector(movePluginDown(_:)))
        down.tag = index
        down.bezelStyle = .rounded
        down.isEnabled = index < engine.slots.count - 1
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove")!, target: self, action: #selector(removePlugin(_:)))
        remove.tag = index
        remove.bezelStyle = .rounded

        let row = NSStackView(views: [number, names, editor, bypass, up, down, remove])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func updateMeters(_ left: Float, _ right: Float) {
        meterLeft.doubleValue = Self.meterValue(left)
        meterRight.doubleValue = Self.meterValue(right)
    }

    private static func meterValue(_ peak: Float) -> Double {
        guard peak > 0.000_01 else { return 0 }
        let db = 20 * log10(Double(peak))
        return max(0, min(1, 1 + db / 60))
    }

    // MARK: - Actions

    @objc private func sourceChanged() {
        engine.settings.sourceDeviceUID = sourcePopup.selectedItem?.representedObject as? String
        muteSwitch.isEnabled = engine.settings.sourceDeviceUID == nil
        engine.applySettings()
    }

    @objc private func outputChanged() {
        engine.settings.outputDeviceUID = outputPopup.selectedItem?.representedObject as? String
        engine.applySettings()
    }

    @objc private func bufferChanged() {
        engine.settings.bufferSize = UInt32(bufferPopup.selectedTag())
        engine.applySettings()
    }

    @objc private func muteChanged() {
        engine.settings.muteOriginal = muteSwitch.state == .on
        engine.applySettings()
    }

    @objc private func toggleEngine() {
        engine.toggle()
    }

    @objc private func addPlugin() {
        guard let window else { return }
        let picker = PluginPickerController(components: PluginCatalog.effects())
        pickerController = picker
        picker.onPick = { [weak self] component in
            guard let self else { return }
            self.engine.addPlugin(component) { result in
                switch result {
                case .success(let slot):
                    self.openUI(for: slot)
                case .failure(let error):
                    self.presentError(error.localizedDescription)
                }
            }
        }
        window.beginSheet(picker.window!) { [weak self] _ in self?.pickerController = nil }
    }

    @objc private func openPluginUI(_ sender: NSButton) {
        guard sender.tag < engine.slots.count else { return }
        openUI(for: engine.slots[sender.tag])
    }

    private func openUI(for slot: PluginSlot) {
        if let existing = slot.windowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PluginWindowController(slot: slot)
        controller.onClose = { [weak slot] in slot?.windowController = nil }
        slot.windowController = controller
        controller.showWindow(nil)
    }

    @objc private func toggleBypass(_ sender: NSButton) {
        guard sender.tag < engine.slots.count else { return }
        engine.setBypass(engine.slots[sender.tag], sender.state == .on)
    }

    @objc private func movePluginUp(_ sender: NSButton) {
        guard sender.tag < engine.slots.count else { return }
        engine.movePlugin(engine.slots[sender.tag], by: -1)
    }

    @objc private func movePluginDown(_ sender: NSButton) {
        guard sender.tag < engine.slots.count else { return }
        engine.movePlugin(engine.slots[sender.tag], by: 1)
    }

    @objc private func removePlugin(_ sender: NSButton) {
        guard sender.tag < engine.slots.count else { return }
        engine.removePlugin(engine.slots[sender.tag])
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Spectrum"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

// MARK: - Grouped form helpers (System Settings look)

/// A rounded, bordered container like the grouped boxes in System Settings.
final class GroupBoxView: NSView {
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    func addRows(_ rows: [FormRow]) {
        if stack.superview == nil {
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

/// Title + optional subtitle on the left, control on the right.
final class FormRow: NSStackView {
    init(title: String, subtitle: String? = nil, control: NSView) {
        super.init(frame: .zero)
        orientation = .horizontal
        distribution = .fill
        alignment = .centerY
        spacing = 12
        edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13)
        let labels = NSStackView(views: [titleField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        if let subtitle {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            labels.addArrangedSubview(sub)
        }
        labels.setContentHuggingPriority(.init(1), for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(labels)
        addArrangedSubview(control)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Document view that lays out from the top so the plugin list grows downward.
private final class FlippedClipDocument: NSView {
    override var isFlipped: Bool { true }
}
