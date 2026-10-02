import AppKit
import AVFoundation

/// The control panel: source, output, buffer size, plugin chain, meters and start/stop.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let engine: AudioEngineController
    /// Called when the user closes the window; the app decides what to do (hide to the menu bar).
    var onHide: (() -> Void)?

    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let outputPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bufferPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let muteCheck = NSButton(checkboxWithTitle: "Silenciar el audio original (escuchar solo la señal procesada)", target: nil, action: nil)
    private let pluginStack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Sin plugins. Pulsa “Añadir plugin…” para cargar, por ejemplo, FabFilter Pro-Q 4.")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let meterLeft = NSLevelIndicator()
    private let meterRight = NSLevelIndicator()
    private let startButton = NSButton(title: "Iniciar", target: nil, action: nil)
    private var pickerController: PluginPickerController?
    private var devices: [AudioDevice] = []
    private var meterDecayTimer: Timer?

    init(engine: AudioEngineController) {
        self.engine = engine
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Spectrum"
        window.minSize = NSSize(width: 560, height: 480)
        window.center()
        window.setFrameAutosaveName("SpectrumMainWindow")
        super.init(window: window)
        window.delegate = self
        buildUI()

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

    // MARK: - Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let header = NSTextField(labelWithString: "Spectrum")
        header.font = .systemFont(ofSize: 22, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: "Escucha el audio de tu Mac a través de plugins Audio Unit en tiempo real.")
        subtitle.textColor = .secondaryLabelColor

        sourcePopup.target = self; sourcePopup.action = #selector(sourceChanged)
        outputPopup.target = self; outputPopup.action = #selector(outputChanged)
        bufferPopup.target = self; bufferPopup.action = #selector(bufferChanged)
        for size in [64, 128, 256, 512, 1024] {
            bufferPopup.addItem(withTitle: "\(size) frames")
            bufferPopup.lastItem?.tag = size
        }
        muteCheck.target = self; muteCheck.action = #selector(muteChanged)

        let grid = NSGridView(views: [
            [label("Fuente"), sourcePopup],
            [label("Salida"), outputPopup],
            [label("Buffer"), bufferPopup],
            [NSView(), muteCheck],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 380

        let pluginsHeader = NSTextField(labelWithString: "Cadena de plugins")
        pluginsHeader.font = .systemFont(ofSize: 15, weight: .semibold)
        let addButton = NSButton(title: "Añadir plugin…", target: self, action: #selector(addPlugin))
        addButton.bezelStyle = .rounded
        let pluginsHeaderRow = NSStackView(views: [pluginsHeader, NSView(), addButton])
        pluginsHeaderRow.orientation = .horizontal

        pluginStack.orientation = .vertical
        pluginStack.alignment = .leading
        pluginStack.spacing = 6
        emptyLabel.textColor = .secondaryLabelColor

        let pluginScroll = NSScrollView()
        let flipped = FlippedClipDocument()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        pluginStack.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(pluginStack)
        pluginScroll.documentView = flipped
        pluginScroll.hasVerticalScroller = true
        pluginScroll.borderType = .bezelBorder
        pluginScroll.drawsBackground = true
        NSLayoutConstraint.activate([
            pluginStack.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 8),
            pluginStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 8),
            pluginStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor, constant: -8),
            pluginStack.bottomAnchor.constraint(lessThanOrEqualTo: flipped.bottomAnchor, constant: -8),
            flipped.widthAnchor.constraint(equalTo: pluginScroll.contentView.widthAnchor),
            flipped.heightAnchor.constraint(greaterThanOrEqualTo: pluginScroll.contentView.heightAnchor),
        ])

        for meter in [meterLeft, meterRight] {
            meter.levelIndicatorStyle = .continuousCapacity
            meter.minValue = 0
            meter.maxValue = 1
            meter.warningValue = 0.8
            meter.criticalValue = 0.97
            meter.doubleValue = 0
            meter.heightAnchor.constraint(equalToConstant: 8).isActive = true
        }
        let meters = NSStackView(views: [meterLeft, meterRight])
        meters.orientation = .vertical
        meters.spacing = 3
        meters.alignment = .leading
        meterLeft.widthAnchor.constraint(equalToConstant: 220).isActive = true
        meterRight.widthAnchor.constraint(equalToConstant: 220).isActive = true

        startButton.target = self
        startButton.action = #selector(toggleEngine)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.controlSize = .large

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let bottom = NSStackView(views: [meters, statusLabel, startButton])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 14
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [header, subtitle, grid, separator(), pluginsHeaderRow, pluginScroll, separator(), bottom])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            subtitle.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            pluginsHeaderRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            pluginScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            pluginScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            bottom.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
        ])
        for sep in root.arrangedSubviews where sep is NSBox {
            sep.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        field.textColor = .secondaryLabelColor
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
        sourcePopup.addItem(withTitle: "Audio del sistema (todas las apps)")
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
            let suffix = device.id == defaultOutput ? " · predeterminada" : ""
            outputPopup.addItem(withTitle: device.name + suffix)
            outputPopup.lastItem?.representedObject = device.uid
        }
        if let uid = engine.settings.outputDeviceUID,
           let index = outputPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == uid }) {
            outputPopup.selectItem(at: index)
        } else if let index = outputPopup.itemArray.firstIndex(where: { $0.title.hasSuffix("predeterminada") }) {
            outputPopup.selectItem(at: index)
        }

        bufferPopup.selectItem(withTag: Int(engine.settings.bufferSize))
        if bufferPopup.selectedItem == nil { bufferPopup.selectItem(withTag: 256) }
        muteCheck.state = engine.settings.muteOriginal ? .on : .off
        muteCheck.isEnabled = engine.settings.sourceDeviceUID == nil
    }

    // MARK: - Refresh

    func refresh() {
        startButton.title = engine.isRunning ? "Detener" : "Iniciar"
        if let error = engine.lastError {
            statusLabel.stringValue = "⚠️ \(error)"
            statusLabel.textColor = .systemRed
        } else if engine.isRunning {
            statusLabel.stringValue = "● En marcha · \(engine.statusDetail)"
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = "○ Detenido"
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
            pluginStack.addArrangedSubview(emptyLabel)
            return
        }
        for (index, slot) in engine.slots.enumerated() {
            let view = row(for: slot, index: index)
            pluginStack.addArrangedSubview(view)
            // Constrain only once both views share a superview, otherwise AppKit throws.
            view.widthAnchor.constraint(equalTo: pluginStack.widthAnchor).isActive = true
        }
    }

    private func row(for slot: PluginSlot, index: Int) -> NSView {
        let number = NSTextField(labelWithString: "\(index + 1).")
        number.textColor = .secondaryLabelColor
        number.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let name = NSTextField(labelWithString: slot.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let maker = NSTextField(labelWithString: slot.supportsStereo ? slot.manufacturer : "\(slot.manufacturer) · no admite estéreo, omitido")
        maker.font = .systemFont(ofSize: 11)
        maker.textColor = slot.supportsStereo ? .secondaryLabelColor : .systemOrange
        let names = NSStackView(views: [name, maker])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        names.setContentHuggingPriority(.defaultLow, for: .horizontal)
        names.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let ui = NSButton(title: "Interfaz", target: self, action: #selector(openPluginUI(_:)))
        ui.tag = index
        ui.bezelStyle = .rounded
        let bypass = NSButton(checkboxWithTitle: "Bypass", target: self, action: #selector(toggleBypass(_:)))
        bypass.tag = index
        bypass.state = slot.bypassed ? .on : .off
        let up = NSButton(title: "▲", target: self, action: #selector(movePluginUp(_:)))
        up.tag = index
        up.bezelStyle = .rounded
        up.isEnabled = index > 0
        let down = NSButton(title: "▼", target: self, action: #selector(movePluginDown(_:)))
        down.tag = index
        down.bezelStyle = .rounded
        down.isEnabled = index < engine.slots.count - 1
        let remove = NSButton(title: "Quitar", target: self, action: #selector(removePlugin(_:)))
        remove.tag = index
        remove.bezelStyle = .rounded

        let row = NSStackView(views: [number, names, ui, bypass, up, down, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
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
        muteCheck.isEnabled = engine.settings.sourceDeviceUID == nil
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
        engine.settings.muteOriginal = muteCheck.state == .on
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

/// Document view that lays out from the top so the plugin list grows downward.
private final class FlippedClipDocument: NSView {
    override var isFlipped: Bool { true }
}
