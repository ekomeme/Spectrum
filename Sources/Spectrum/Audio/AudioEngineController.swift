import AVFoundation
import CoreAudio
import Foundation

enum EngineError: LocalizedError {
    case noOutputDevice
    case inputDeviceNotFound
    case unsupportedStreamFormat
    case instantiationFailed(String)
    case pluginNotInstalled(String)
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .noOutputDevice: return "No output device is available."
        case .inputDeviceNotFound: return "The selected input device is no longer available."
        case .unsupportedStreamFormat: return "The device uses an unsupported audio format (Float32 expected)."
        case .instantiationFailed(let name): return "Could not load the plugin \(name)."
        case .pluginNotInstalled(let name): return "The plugin \(name) is no longer installed."
        case .microphoneDenied: return "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
        }
    }
}

/// Owns the processing chain:  aggregate device IOProc → RealtimeRenderer → [AU plugins…] → device.
/// Plugins stay initialised across stop/start; only the device side is torn down and rebuilt.
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

    private let clock = TransportClock()
    private let feed = InputFeed()
    private var tap: SystemAudioTap?
    private var aggregate: AggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var renderer: RealtimeRenderer?
    private var sampleRate: Double = 48_000
    private var meterTimer: Timer?
    private var restartWork: DispatchWorkItem?
    /// Removed plugins are kept alive briefly so their editor views can finish tearing down.
    private var retiring: [PluginSlot] = []
    private static let maxFrames = 4096

    init() {
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
            sourceName = "System audio"
        }

        let device = try AggregateDevice(output: output, input: inputDevice, tapUUID: tapUUID)
        aggregate = device
        device.setBufferFrameSize(settings.bufferSize)

        sampleRate = device.sampleRate > 0 ? device.sampleRate : 48_000
        if let streamFormat = device.streamFormat(scope: kAudioObjectPropertyScopeOutput), !streamFormat.isFloat32 {
            throw EngineError.unsupportedStreamFormat
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw EngineError.unsupportedStreamFormat
        }
        clock.sampleRate = sampleRate

        // Plugins are only (re)initialised when the sample rate changes.
        for slot in slots { prepareIfNeeded(slot) }
        let realtime = RealtimeRenderer(format: format, maxFrames: Self.maxFrames, clock: clock, feed: feed)
        renderer = realtime
        publishChain()

        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) { _, inputData, _, outputData, outputTime in
            realtime.process(input: inputData, output: outputData, timestamp: outputTime)
        }
        guard status == noErr, let procID else { throw CoreAudioError.status(status, "Could not create the audio I/O procedure") }
        ioProcID = procID
        status = AudioDeviceStart(device.id, procID)
        guard status == noErr else { throw CoreAudioError.status(status, "Could not start the audio device") }

        isRunning = true
        clock.isPlaying = true
        statusDetail = "\(sourceName) → \(output.name) · \(Int(sampleRate)) Hz · \(device.bufferFrameSize) frames"
        startMeterTimer()
    }

    private func stopInternal() {
        restartWork?.cancel()
        meterTimer?.invalidate()
        meterTimer = nil
        renderer?.setChain([])
        if let aggregate, let ioProcID {
            AudioDeviceStop(aggregate.id, ioProcID)
            AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
        }
        ioProcID = nil
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

    // MARK: - Plugin chain

    /// Initialises the plugin through the classic v2 API for the current sample rate (no-op if already done).
    /// The v3 bridge's renderBlock reports "no connection" for v2 plugins with side-chain buses, so hosting
    /// goes through AudioUnitRender like a DAW.
    private func prepareIfNeeded(_ slot: PluginSlot) {
        guard slot.supportsStereo else { return }
        let au = slot.unit.audioUnit
        if slot.preparedSampleRate == sampleRate { return }
        if slot.preparedSampleRate > 0 { AudioUnitUninitialize(au) }
        slot.preparedSampleRate = 0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        var asbd = format.streamDescription.pointee
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, asbdSize)
        guard status == noErr else { lastError = "\(slot.name): input format rejected (\(status))"; return }
        status = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, asbdSize)
        guard status == noErr else { lastError = "\(slot.name): output format rejected (\(status))"; return }
        var maxFrames = UInt32(Self.maxFrames)
        AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)
        var callback = AURenderCallbackStruct(inputProc: InputFeed.renderCallback, inputProcRefCon: feed.opaque)
        status = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { lastError = "\(slot.name): does not accept a render callback (\(status))"; return }
        clock.installV2HostCallbacks(on: au)
        status = AudioUnitInitialize(au)
        guard status == noErr else { lastError = "\(slot.name): could not be initialised (\(status))"; return }
        slot.preparedSampleRate = sampleRate
    }

    /// Hands the current chain to the realtime thread. Cheap and glitch-free: no plugin is re-initialised.
    private func publishChain() {
        guard let renderer else { return }
        let stages: [RealtimeRenderer.Stage] = slots.compactMap { slot in
            guard slot.supportsStereo, slot.preparedSampleRate > 0 else { return nil }
            return RealtimeRenderer.Stage(id: slot.id, audioUnit: slot.unit.audioUnit)
        }
        renderer.setChain(stages)
    }

    private func adopt(_ slot: PluginSlot) {
        slots.append(slot)
        if isRunning {
            prepareIfNeeded(slot)
            publishChain()
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
                self.adopt(slot)
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
        publishChain()
        retiring.append(slot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.retiring.removeAll { $0.id == slot.id }
            if slot.preparedSampleRate > 0 { AudioUnitUninitialize(slot.unit.audioUnit); slot.preparedSampleRate = 0 }
        }
        notify()
    }

    func movePlugin(_ slot: PluginSlot, by offset: Int) {
        guard let index = slots.firstIndex(where: { $0.id == slot.id }) else { return }
        let target = index + offset
        guard target >= 0, target < slots.count else { return }
        slots.swapAt(index, target)
        publishChain()
        notify()
    }

    /// Moves a plugin to an arbitrary position (drag and drop reordering).
    func movePlugin(from source: Int, to destination: Int) {
        guard source >= 0, source < slots.count, destination >= 0, destination <= slots.count else { return }
        var target = destination
        if source < target { target -= 1 }
        guard source != target else { return }
        let slot = slots.remove(at: source)
        slots.insert(slot, at: target)
        publishChain()
        notify()
    }

    func setBypass(_ slot: PluginSlot, _ bypassed: Bool) {
        slot.bypassed = bypassed
        notify()
    }

    private func instantiate(_ description: AudioComponentDescription, name: String, manufacturer: String,
                             completion: @escaping (Result<PluginSlot, Error>) -> Void) {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
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

    /// Runs the real signal path for a moment and reports what happened (used by `Spectrum --selftest`).
    func selfTest(sourceUID: String?, outputUID: String?, seconds: Double, toneAmplitude: Float = 0,
                  lateAddComponent: AVAudioUnitComponent? = nil) -> String {
        settings.sourceDeviceUID = sourceUID
        settings.outputDeviceUID = outputUID
        var lines: [String] = []
        func wait(_ seconds: Double) -> Float {
            var peak: Float = 0
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                if let renderer { let (l, r) = renderer.takePeaks(); peak = max(peak, l, r) }
            }
            return peak
        }
        do {
            try startInternal()
            renderer?.testToneAmplitude = toneAmplitude
            lines.append("arrancado: \(statusDetail) · plugins=\(slots.count)")
            let peak = wait(seconds)
            if let lateComponent = lateAddComponent {
                lines.append("añadiendo \(lateComponent.name) con el motor en marcha…")
                var done = false
                addPlugin(lateComponent) { result in
                    if case .failure(let error) = result { lines.append("  fallo: \(error.localizedDescription)") }
                    done = true
                }
                while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                lines.append("  plugins=\(slots.count) preparado a \(slots.last?.preparedSampleRate ?? 0) Hz · isRunning=\(isRunning)")
                lines.append("  pico tras añadir: \(wait(1)) · renders fallidos: \(renderer?.overloadCount ?? 0) · primer error: \(renderer?.firstErrorStatus ?? 0) \(fourCC(renderer?.firstErrorStatus ?? 0))")
                if let last = slots.last {
                    removePlugin(last)
                    lines.append("  quitado; plugins=\(slots.count) · pico tras quitar: \(wait(0.5))")
                }
            }
            lines.append("pico de salida: \(peak) · renders fallidos: \(renderer?.overloadCount ?? 0)")
            if let stats = renderer?.statistics {
                lines.append("IOProc: \(stats.0) callbacks · entrada \(stats.1) ch · salida \(stats.2) ch · \(stats.3) frames/callback")
            }
            // Stop/start cycle: plugins must stay allocated and the chain must come back.
            let allocatedBefore = slots.map { $0.preparedSampleRate }
            stopInternal()
            try startInternal()
            renderer?.testToneAmplitude = toneAmplitude
            let allocatedAfter = slots.map { $0.preparedSampleRate }
            lines.append("tras detener/iniciar: recursos antes \(allocatedBefore) después \(allocatedAfter) · pico \(wait(0.7)) · posición transporte \(clock.samplePosition)")
        } catch {
            lines.append("Error: \(error.localizedDescription)")
        }
        stopInternal()
        lines.append("detenido limpiamente")
        return lines.joined(separator: "\n")
    }

    /// Compares "add while running" vs "restore from session then start" for one plugin.
    func transportProbe(component: AVAudioUnitComponent, restoreState: Data?, sourceUID: String?, outputUID: String?) -> String {
        settings.sourceDeviceUID = sourceUID
        settings.outputDeviceUID = outputUID
        var lines: [String] = []
        func wait(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        func load(then: @escaping (PluginSlot) -> Void) {
            instantiate(component.audioComponentDescription, name: component.name, manufacturer: component.manufacturerName) { result in
                if case .success(let slot) = result { then(slot) } else { lines.append("  fallo al instanciar") }
            }
        }
        func deltas(_ label: String, _ before: [UInt32]) {
            let c = clock.callCounts
            lines.append("  \(label): v3 transport \(c[0]-before[0]) · v3 musical \(c[1]-before[1]) · v2 transport \(c[2]-before[2]) · renders fallidos \(renderer?.overloadCount ?? 0)")
        }

        lines.append("A) añadir en caliente (motor ya en marcha)")
        do { try startInternal() } catch { return "Error al arrancar: \(error.localizedDescription)" }
        var slotA: PluginSlot?
        var before = clock.callCounts
        load { slot in self.adopt(slot); slotA = slot }
        while slotA == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        wait(1.5)
        deltas("tras 1.5 s", before)
        lines.append("B) detener e iniciar con el plugin cargado")
        before = clock.callCounts
        stopInternal()
        do { try startInternal() } catch { return lines.joined(separator: "\n") }
        wait(1.5)
        deltas("tras 1.5 s", before)
        if let slotA { removePlugin(slotA) }
        stopInternal()

        lines.append("C) restaurar desde sesión (fullState) y luego arrancar")
        var slotB: PluginSlot?
        load { slot in slot.restore(state: restoreState); self.adopt(slot); slotB = slot }
        while slotB == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        before = clock.callCounts
        do { try startInternal() } catch { return lines.joined(separator: "\n") }
        wait(1.5)
        deltas("tras 1.5 s (estado \(restoreState?.count ?? 0) bytes)", before)
        if let slotB { removePlugin(slotB) }
        stopInternal()
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
                    lastError = "Could not restore: " + failures.joined(separator: ", ")
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
                    self.adopt(slot)
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
