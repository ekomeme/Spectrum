import AVFoundation
import CoreAudio
import Foundation

enum EngineError: LocalizedError {
    case noOutputDevice
    case inputDeviceNotFound
    case unsupportedStreamFormat
    case manualRenderingUnavailable
    case instantiationFailed(String)
    case pluginNotInstalled(String)
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .noOutputDevice: return "No hay ningún dispositivo de salida disponible."
        case .inputDeviceNotFound: return "El dispositivo de entrada seleccionado ya no está disponible."
        case .unsupportedStreamFormat: return "El dispositivo usa un formato de audio no compatible (se esperaba Float32)."
        case .manualRenderingUnavailable: return "No se pudo configurar el motor de audio en modo tiempo real."
        case .instantiationFailed(let name): return "No se pudo cargar el plugin \(name)."
        case .pluginNotInstalled(let name): return "El plugin \(name) ya no está instalado."
        case .microphoneDenied: return "Acceso al micrófono denegado. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono."
        }
    }
}

/// Owns the processing chain:  aggregate device IOProc → AVAudioEngine (manual realtime rendering):
/// inputNode → inputMixer → [AU plugins…] → mainMixer → outputNode → back to the device.
final class AudioEngineController {
    var settings = EngineSettings()
    private(set) var slots: [PluginSlot] = []
    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var statusDetail: String = ""

    /// Fired on the main thread whenever running state, error or plugin list changes.
    var onStateChange: (() -> Void)?
    /// Peak levels (0…1 linear) for left/right, on the main thread, ~30 times per second while running.
    var onLevel: ((Float, Float) -> Void)?

    private let engine = AVAudioEngine()
    private let inputMixer = AVAudioMixerNode()
    private let clock = TransportClock()
    private var tap: SystemAudioTap?
    private var aggregate: AggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var renderer: RealtimeRenderer?
    private var processFormat: AVAudioFormat?
    private var meterTimer: Timer?
    private var restartWork: DispatchWorkItem?
    /// Removed plugins are kept alive briefly so their editor views can finish tearing down.
    private var retiring: [PluginSlot] = []
    private static let maxFrames = 4096

    init() {
        engine.attach(inputMixer)
        AudioDeviceManager.shared.addObserver { [weak self] in self?.handleDeviceListChange() }
    }

    // MARK: - Lifecycle

    func start() {
        if settings.sourceDeviceUID != nil, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.start() }
            }
            return
        }
        do {
            try startInternal()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            stopInternal()
        }
        notify()
    }

    func stop() {
        stopInternal()
        notify()
    }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    /// Call after changing `settings` to apply them live.
    func applySettings() {
        if isRunning {
            stopInternal()
            start()
        } else {
            notify()
        }
    }

    func shutdown() {
        stopInternal()
        for slot in slots { slot.windowController?.dispose() }
    }

    private func startInternal() throws {
        stopInternal()
        let devices = AudioDeviceManager.shared.allDevices()

        let output: AudioDevice
        if let uid = settings.outputDeviceUID, let match = devices.first(where: { $0.uid == uid && $0.hasOutput }) {
            output = match
        } else if let defaultID = AudioDeviceManager.shared.defaultOutputDeviceID(),
                  let match = devices.first(where: { $0.id == defaultID && $0.hasOutput }) {
            output = match
        } else if let any = devices.first(where: \.hasOutput) {
            output = any
        } else {
            throw EngineError.noOutputDevice
        }

        var inputDevice: AudioDevice?
        var tapUUID: UUID?
        let sourceName: String
        if let uid = settings.sourceDeviceUID {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied { throw EngineError.microphoneDenied }
            guard let match = devices.first(where: { $0.uid == uid && $0.hasInput }) else { throw EngineError.inputDeviceNotFound }
            inputDevice = match
            sourceName = match.name
        } else {
            let systemTap = try SystemAudioTap(muteOriginal: settings.muteOriginal)
            tap = systemTap
            tapUUID = systemTap.uuid
            sourceName = "Audio del sistema"
        }

        let device = try AggregateDevice(output: output, input: inputDevice, tapUUID: tapUUID)
        aggregate = device
        device.setBufferFrameSize(settings.bufferSize)

        let sampleRate = device.sampleRate > 0 ? device.sampleRate : 48_000
        if let streamFormat = device.streamFormat(scope: kAudioObjectPropertyScopeOutput), !streamFormat.isFloat32 {
            throw EngineError.unsupportedStreamFormat
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw EngineError.manualRenderingUnavailable
        }
        processFormat = format
        clock.sampleRate = sampleRate
        let realtime = RealtimeRenderer(format: format, maxFrames: Self.maxFrames, clock: clock)
        renderer = realtime

        try configureEngine(with: realtime)

        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) { _, inputData, _, outputData, _ in
            realtime.process(input: inputData, output: outputData)
        }
        guard status == noErr, let procID else { throw CoreAudioError.status(status, "No se pudo crear el proceso de E/S") }
        ioProcID = procID
        status = AudioDeviceStart(device.id, procID)
        guard status == noErr else { throw CoreAudioError.status(status, "No se pudo arrancar el dispositivo de audio") }

        isRunning = true
        clock.isPlaying = true
        statusDetail = "\(sourceName) → \(output.name) · \(Int(sampleRate)) Hz · \(device.bufferFrameSize) frames"
        startMeterTimer()
    }

    private func stopInternal() {
        restartWork?.cancel()
        meterTimer?.invalidate()
        meterTimer = nil
        renderer?.setRenderBlock(nil)
        if let aggregate, let ioProcID {
            AudioDeviceStop(aggregate.id, ioProcID)
            AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
        }
        ioProcID = nil
        if engine.isRunning { engine.stop() }
        aggregate?.destroy()
        aggregate = nil
        tap?.destroy()
        tap = nil
        renderer = nil
        isRunning = false
        clock.isPlaying = false
        statusDetail = ""
        onLevel?(0, 0)
    }

    // MARK: - Engine graph

    /// Puts the engine in realtime manual-rendering mode, wires the chain and hands the render block to the IOProc.
    private func configureEngine(with realtime: RealtimeRenderer) throws {
        realtime.setRenderBlock(nil)
        if engine.isRunning { engine.stop() }
        try engine.enableManualRenderingMode(.realtime, format: realtime.format, maximumFrameCount: AVAudioFrameCount(Self.maxFrames))
        if inputMixer.engine == nil { engine.attach(inputMixer) }
        for slot in slots where slot.unit.engine == nil { engine.attach(slot.unit) }
        connectGraph(format: realtime.format)
        guard engine.inputNode.setManualRenderingInputPCMFormat(realtime.format, inputBlock: { frameCount in
            realtime.inputList(for: frameCount)
        }) else { throw EngineError.manualRenderingUnavailable }
        engine.prepare()
        try engine.start()
        realtime.setRenderBlock(engine.manualRenderingBlock)
    }

    private func connectGraph(format: AVAudioFormat) {
        disconnectGraph()
        engine.connect(engine.inputNode, to: inputMixer, format: format)
        var previous: AVAudioNode = inputMixer
        for slot in slots where slot.supportsStereo {
            engine.connect(previous, to: slot.unit, format: format)
            previous = slot.unit
        }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
    }

    private func disconnectGraph() {
        engine.disconnectNodeOutput(engine.inputNode)
        engine.disconnectNodeInput(inputMixer)
        engine.disconnectNodeOutput(inputMixer)
        for slot in slots {
            engine.disconnectNodeInput(slot.unit)
            engine.disconnectNodeOutput(slot.unit)
        }
        engine.disconnectNodeInput(engine.mainMixerNode)
        engine.disconnectNodeOutput(engine.mainMixerNode)
    }

    /// Re-wire the plugin chain while the device keeps running (a few ms of silence, no device teardown).
    private func rewireChain() {
        guard isRunning, let renderer else { return }
        do {
            try configureEngine(with: renderer)
        } catch {
            lastError = error.localizedDescription
            stopInternal()
        }
    }

    private func handleDeviceListChange() {
        guard isRunning else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.start()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: - Metering

    private func startMeterTimer() {
        meterTimer?.invalidate()
        var held: (Float, Float) = (0, 0)
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let renderer = self.renderer else { return }
            let (left, right) = renderer.takePeaks()
            // Fast attack, slow release so the meter is readable.
            held.0 = max(left, held.0 * 0.85)
            held.1 = max(right, held.1 * 0.85)
            self.onLevel?(held.0, held.1)
        }
        RunLoop.main.add(meterTimer!, forMode: .common)
    }

    // MARK: - Plugins

    func addPlugin(_ component: AVAudioUnitComponent, completion: @escaping (Result<PluginSlot, Error>) -> Void) {
        instantiate(component.audioComponentDescription, name: component.name, manufacturer: component.manufacturerName) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let slot):
                self.engine.attach(slot.unit)
                self.slots.append(slot)
                self.rewireChain()
                self.notify()
                completion(.success(slot))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func removePlugin(_ slot: PluginSlot) {
        guard let index = slots.firstIndex(where: { $0.id == slot.id }) else { return }
        slot.windowController?.dispose()
        slot.windowController = nil
        slots.remove(at: index)
        renderer?.setRenderBlock(nil)
        if engine.isRunning { engine.stop() }
        engine.disconnectNodeInput(slot.unit)
        engine.disconnectNodeOutput(slot.unit)
        engine.detach(slot.unit)
        retiring.append(slot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.retiring.removeAll { $0.id == slot.id }
        }
        rewireChain()
        notify()
    }

    func movePlugin(_ slot: PluginSlot, by offset: Int) {
        guard let index = slots.firstIndex(where: { $0.id == slot.id }) else { return }
        let target = index + offset
        guard target >= 0, target < slots.count else { return }
        slots.swapAt(index, target)
        rewireChain()
        notify()
    }

    func setBypass(_ slot: PluginSlot, _ bypassed: Bool) {
        slot.bypassed = bypassed
        notify()
    }

    private func instantiate(_ description: AudioComponentDescription, name: String, manufacturer: String,
                             completion: @escaping (Result<PluginSlot, Error>) -> Void) {
        let format = processFormat ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        AVAudioUnit.instantiate(with: description, options: []) { unit, error in
            DispatchQueue.main.async {
                guard let unit else {
                    completion(.failure(error ?? EngineError.instantiationFailed(name)))
                    return
                }
                let slot = PluginSlot(unit: unit, name: name, manufacturer: manufacturer, processFormat: format)
                self.clock.install(on: unit)
                completion(.success(slot))
            }
        }
    }

    // MARK: - Diagnostics

    /// Compares "add while running" vs "restore from session then start" for one plugin.
    func transportProbe(component: AVAudioUnitComponent, restoreState: Data?, sourceUID: String?, outputUID: String?) -> String {
        settings.sourceDeviceUID = sourceUID
        settings.outputDeviceUID = outputUID
        var lines: [String] = []
        func wait(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        func load(then: @escaping (PluginSlot) -> Void) {
            instantiate(component.audioComponentDescription, name: component.name, manufacturer: component.manufacturerName) { result in
                if case .success(let slot) = result { then(slot) } else { lines.append("  fallo al instanciar"); }
            }
        }
        func report(_ label: String, _ slot: PluginSlot) {
            let c = clock.callCounts
            lines.append("  \(label): v3 transport \(c[0]) · v3 musical \(c[1]) · v2 transport \(c[2]) · v2 beatTempo \(c[3]) · v2 timeLoc \(c[4]) · hostCallbacks propios: \(clock.hostCallbacksInstalled(on: slot.unit.audioUnit)) · bypass \(slot.bypassed)")
        }

        lines.append("A) añadir en caliente (motor ya en marcha)")
        do { try startInternal() } catch { return "Error al arrancar: \(error.localizedDescription)" }
        var slotA: PluginSlot?
        load { slot in self.engine.attach(slot.unit); self.slots.append(slot); self.rewireChain(); slotA = slot }
        while slotA == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        wait(1.5)
        if let slotA { report("tras 1.5 s", slotA) }
        if let slotA { removePlugin(slotA) }
        stopInternal()

        lines.append("B) restaurar desde sesión (fullState) y luego arrancar")
        var slotB: PluginSlot?
        load { slot in
            slot.restore(state: restoreState)
            self.engine.attach(slot.unit); self.slots.append(slot); slotB = slot
        }
        while slotB == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let before = clock.callCounts
        do { try startInternal() } catch { return lines.joined(separator: "\n") + "\nError al arrancar: \(error.localizedDescription)" }
        wait(1.5)
        if let slotB {
            let c = clock.callCounts
            lines.append("  deltas tras 1.5 s: v3 transport \(c[0]-before[0]) · v3 musical \(c[1]-before[1]) · v2 transport \(c[2]-before[2]) · v2 beatTempo \(c[3]-before[3]) · v2 timeLoc \(c[4]-before[4]) · hostCallbacks propios: \(clock.hostCallbacksInstalled(on: slotB.unit.audioUnit)) · bypass \(slotB.bypassed) · estado restaurado: \(restoreState?.count ?? 0) bytes")
        }

        lines.append("C) mismo plugin restaurado, SIN fullState")
        if let slotB { removePlugin(slotB) }
        stopInternal()
        var slotC: PluginSlot?
        load { slot in self.engine.attach(slot.unit); self.slots.append(slot); slotC = slot }
        while slotC == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let before2 = clock.callCounts
        do { try startInternal() } catch { return lines.joined(separator: "\n") }
        wait(1.5)
        let c2 = clock.callCounts
        lines.append("  deltas tras 1.5 s: v3 transport \(c2[0]-before2[0]) · v3 musical \(c2[1]-before2[1]) · v2 transport \(c2[2]-before2[2]) · v2 beatTempo \(c2[3]-before2[3]) · v2 timeLoc \(c2[4]-before2[4])")
        stopInternal()
        return lines.joined(separator: "\n")
    }

    /// Runs the real signal path for a moment and reports what happened (used by `Spectrum --selftest`).
    func selfTest(sourceUID: String?, outputUID: String?, seconds: Double, toneAmplitude: Float = 0,
                  lateAddComponent: AVAudioUnitComponent? = nil) -> String {
        settings.sourceDeviceUID = sourceUID
        settings.outputDeviceUID = outputUID
        var lines: [String] = []
        do {
            try startInternal()
            renderer?.testToneAmplitude = toneAmplitude
            lines.append("arrancado: \(statusDetail)")
            lines.append("engine.isRunning=\(engine.isRunning) manualRenderingMode=\(engine.manualRenderingMode.rawValue) plugins=\(slots.count)")
            let deadline = Date().addingTimeInterval(seconds)
            var peak: Float = 0
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                if let renderer { let (l, r) = renderer.takePeaks(); peak = max(peak, l, r) }
            }
            if let lateComponent = lateAddComponent {
                lines.append("añadiendo \(lateComponent.name) con el motor en marcha…")
                var done = false
                addPlugin(lateComponent) { result in
                    if case .failure(let error) = result { lines.append("  fallo: \(error.localizedDescription)") }
                    done = true
                }
                while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                lines.append("  plugins=\(slots.count) engine.isRunning=\(engine.isRunning) isRunning=\(isRunning)")
                let until = Date().addingTimeInterval(1)
                var latePeak: Float = 0
                while Date() < until {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    if let renderer { let (l, r) = renderer.takePeaks(); latePeak = max(latePeak, l, r) }
                }
                lines.append("  pico tras añadir: \(latePeak) · renders fallidos: \(renderer?.overloadCount ?? 0)")
                if let last = slots.last {
                    removePlugin(last)
                    lines.append("  quitado; plugins=\(slots.count) engine.isRunning=\(engine.isRunning) isRunning=\(isRunning)")
                    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                    if let renderer { let (l, r) = renderer.takePeaks(); lines.append("  pico tras quitar: \(max(l, r))") }
                }
            }
            lines.append("pico de salida: \(peak) · renders fallidos: \(renderer?.overloadCount ?? 0)")
            if let stats = renderer?.statistics {
                lines.append("IOProc: \(stats.0) callbacks · entrada \(stats.1) ch · salida \(stats.2) ch · \(stats.3) frames/callback")
            }
        } catch {
            lines.append("Error: \(error.localizedDescription)")
        }
        stopInternal()
        lines.append("detenido limpiamente")
        return lines.joined(separator: "\n")
    }

    // MARK: - Session persistence

    private static var sessionURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Spectrum", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.plist")
    }

    func saveSession() {
        let session = Session(settings: settings, plugins: slots.map { $0.savedState() }, wasRunning: isRunning)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(session) {
            try? data.write(to: Self.sessionURL, options: .atomic)
        }
    }

    /// Restores settings and the plugin chain, then starts the engine if it was running last time.
    func restoreSession(completion: @escaping () -> Void) {
        guard let data = try? Data(contentsOf: Self.sessionURL),
              let session = try? PropertyListDecoder().decode(Session.self, from: data) else {
            completion()
            return
        }
        settings = session.settings
        var pending = session.plugins
        var failures: [String] = []

        func next() {
            guard !pending.isEmpty else {
                if !failures.isEmpty {
                    lastError = "No se pudieron restaurar: " + failures.joined(separator: ", ")
                }
                if session.wasRunning { start() } else { notify() }
                completion()
                return
            }
            let saved = pending.removeFirst()
            guard PluginCatalog.component(matching: saved.componentDescription) != nil else {
                failures.append(saved.name)
                next()
                return
            }
            instantiate(saved.componentDescription, name: saved.name, manufacturer: saved.manufacturerName) { [weak self] result in
                guard let self else { return }
                if case .success(let slot) = result {
                    slot.restore(state: saved.state)
                    slot.bypassed = saved.bypassed
                    self.engine.attach(slot.unit)
                    self.slots.append(slot)
                } else {
                    failures.append(saved.name)
                }
                next()
            }
        }
        next()
    }

    private func notify() {
        if Thread.isMainThread {
            onStateChange?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
        }
    }
}
