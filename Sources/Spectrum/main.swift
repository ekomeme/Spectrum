import AppKit
import AVFoundation

setvbuf(stdout, nil, _IONBF, 0)

// Diagnostic mode: `Spectrum --list` prints devices and AU effects without opening a window.
if CommandLine.arguments.contains("--list") {
    print("== Dispositivos de audio ==")
    for device in AudioDeviceManager.shared.allDevices() {
        print("  [\(device.id)] \(device.name)  in:\(device.inputChannels) out:\(device.outputChannels)  uid:\(device.uid)")
    }
    print("== Plugins AU (efectos) ==")
    for component in PluginCatalog.effects() {
        print("  \(component.manufacturerName) – \(component.name)  v\(component.versionString)")
    }
    exit(0)
}

// Diagnostic mode: `Spectrum --probe "<nombre>"` instantiates a plugin and reports formats/UI support.
if let index = CommandLine.arguments.firstIndex(of: "--probe"), index + 1 < CommandLine.arguments.count {
    let query = CommandLine.arguments[index + 1].lowercased()
    guard let component = PluginCatalog.effects().first(where: { $0.name.lowercased().contains(query) }) else {
        print("No se encontró ningún plugin que contenga “\(query)”")
        exit(1)
    }
    print("Instanciando \(component.manufacturerName) – \(component.name)…")
    let group = DispatchGroup()
    group.enter()
    AVAudioUnit.instantiate(with: component.audioComponentDescription, options: []) { unit, error in
        defer { group.leave() }
        guard let unit else { print("Error: \(error?.localizedDescription ?? "desconocido")"); return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let slot = PluginSlot(unit: unit, name: component.name, manufacturer: component.manufacturerName, processFormat: format)
        print("  estéreo 48 kHz: \(slot.supportsStereo ? "OK" : "NO")")
        print("  buses in/out: \(unit.auAudioUnit.inputBusses.count)/\(unit.auAudioUnit.outputBusses.count)")
        print("  latencia: \(unit.auAudioUnit.latency * 1000) ms")
        print("  parámetros: \(unit.auAudioUnit.parameterTree?.allParameters.count ?? 0)")
        print("  estado serializable: \(slot.savedState().state?.count ?? 0) bytes")
        print("  vista propia: \(unit.auAudioUnit.providesUserInterface)")
    }
    _ = group.wait(timeout: .now() + 20)
    exit(0)
}

// Diagnostic mode: `Spectrum --selftest [inputUID] [outputUID]` runs the real signal path for two seconds.
if let index = CommandLine.arguments.firstIndex(of: "--selftest") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1)).filter { !$0.hasPrefix("--") }
    let controller = AudioEngineController()
    if CommandLine.arguments.contains("--with-proq"),
       let component = PluginCatalog.effects().first(where: { $0.name.lowercased().contains("pro-q") }) {
        var done = false
        controller.addPlugin(component) { result in
            if case .failure(let error) = result { print("plugin: \(error.localizedDescription)") } else { print("plugin Pro-Q 4 cargado") }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let sourceUID: String? = (args.first == "system") ? nil : args.first
    let tone: Float = CommandLine.arguments.contains("--tone") ? 0.02 : 0
    let late = CommandLine.arguments.contains("--add-late") ? PluginCatalog.effects().first(where: { $0.name.lowercased().contains("pro-q") }) : nil
    print(controller.selfTest(sourceUID: sourceUID, outputUID: args.count > 1 ? args[1] : nil, seconds: 2, toneAmplitude: tone, lateAddComponent: late))
    exit(0)
}

// Diagnostic mode: `Spectrum --probe-transport "<nombre>" <inputUID> <outputUID>` compares hot-add vs session-restore.
if let index = CommandLine.arguments.firstIndex(of: "--probe-transport"), index + 3 < CommandLine.arguments.count {
    let query = CommandLine.arguments[index + 1].lowercased()
    guard let component = PluginCatalog.effects().first(where: { $0.name.lowercased().contains(query) }) else { print("sin plugin"); exit(1) }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let url = base.appendingPathComponent("Spectrum/session.plist")
    var state: Data? = nil
    if let data = try? Data(contentsOf: url), let session = try? PropertyListDecoder().decode(Session.self, from: data) {
        state = session.plugins.first(where: { $0.name == component.name })?.state
    }
    let controller = AudioEngineController()
    print(controller.transportProbe(component: component, restoreState: state,
                                    sourceUID: CommandLine.arguments[index + 2], outputUID: CommandLine.arguments[index + 3]))
    exit(0)
}

// Diagnostic mode: `Spectrum --ui-smoke` builds the real window, loads Pro-Q 4 into the list and exits.
if CommandLine.arguments.contains("--ui-smoke") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = AudioEngineController()
    let window = MainWindowController(engine: controller)
    window.showWindow(nil)
    let wanted = (CommandLine.arguments.firstIndex(of: "--ui-smoke").flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil } ?? "pro-q").lowercased()
    guard let component = PluginCatalog.effects().first(where: { $0.name.lowercased().contains(wanted) }) else { print("sin plugin \(wanted)"); exit(1) }
    var done = false
    controller.addPlugin(component) { result in
        if case .failure(let error) = result { print("fallo: \(error.localizedDescription)"); exit(1) }
        done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    print("UI OK: \(controller.slots.count) plugin(s) en la lista, ventana \(window.window?.frame.size ?? .zero)")
    // Open, close and reopen the plugin editor: both times it must be the plugin's own view.
    if let slot = controller.slots.first {
        for attempt in 1...3 {
            let editor = PluginWindowController(slot: slot)
            editor.showWindow(nil)
            let delay = Double(ProcessInfo.processInfo.environment["SPECTRUM_UI_DELAY"] ?? "0.6") ?? 0.6
            RunLoop.main.run(until: Date().addingTimeInterval(delay))
            let viewClass = editor.window?.contentView?.subviews.first.map { String(describing: type(of: $0)) } ?? "nil"
            print("  interfaz intento \(attempt): vista \(viewClass) · tamaño \(editor.window?.contentView?.frame.size ?? .zero) · genérica: \(editor.usedGenericView)")
            editor.dispose()
            RunLoop.main.run(until: Date().addingTimeInterval(max(0.2, delay / 2)))
        }
    }
    if let last = controller.slots.last { controller.removePlugin(last) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    print("UI OK tras quitar: \(controller.slots.count) plugin(s)")
    // Mirror the app's quit path: settle, then end without running plugin static destructors.
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    _exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
