import CoreAudio
import Foundation

enum CoreAudioError: LocalizedError {
    case status(OSStatus, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .status(let code, let what):
            return "\(what) (Core Audio error \(code) '\(fourCC(code))')"
        case .message(let text):
            return text
        }
    }
}

func fourCC(_ value: OSStatus) -> String {
    let bits = UInt32(bitPattern: value)
    let bytes = [UInt8(bits >> 24 & 0xff), UInt8(bits >> 16 & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits & 0xff)]
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return String(value) }
    return String(bytes: bytes, encoding: .ascii) ?? String(value)
}

/// A physical (or virtual) Core Audio device as seen by the user.
struct AudioDevice: Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int

    var hasInput: Bool { inputChannels > 0 }
    var hasOutput: Bool { outputChannels > 0 }
}

/// Thin wrappers around AudioObjectGetPropertyData.
enum CoreAudio {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        initial: T) throws -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { throw CoreAudioError.status(status, "Could not read property \(fourCC(OSStatus(bitPattern: selector)))") }
        return value
    }

    static func readArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             initial: T) throws -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError.status(status, "Could not read property size") }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: initial, count: count)
        status = values.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { throw CoreAudioError.status(status, "Could not read property") }
        return values
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func write<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         value: T) throws {
        var addr = address(selector, scope: scope)
        var copy = value
        let status = withUnsafePointer(to: &copy) { ptr in
            AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), ptr)
        }
        guard status == noErr else { throw CoreAudioError.status(status, "Could not write property \(fourCC(OSStatus(bitPattern: selector)))") }
    }

    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// The Core Audio process object that represents this process (used to exclude ourselves from the system tap).
    static func currentProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &objectID)
        }
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }
}

/// Enumerates devices and notifies when the device list changes.
final class AudioDeviceManager {
    static let shared = AudioDeviceManager()

    private var observers: [() -> Void] = []
    private var listenerInstalled = false
    private var snapshot: Set<String> = []

    private init() {}

    /// Registers a block to run on the main thread whenever the set of devices or the default devices really change.
    func addObserver(_ block: @escaping () -> Void) {
        observers.append(block)
        startListening()
    }

    private func currentSnapshot() -> Set<String> {
        var set = Set(allDevices().map(\.uid))
        if let id = defaultOutputDeviceID() { set.insert("default-output:\(id)") }
        if let id = defaultInputDeviceID() { set.insert("default-input:\(id)") }
        return set
    }

    func allDevices() -> [AudioDevice] {
        let ids = (try? CoreAudio.readArray(CoreAudio.systemObject, kAudioHardwarePropertyDevices, initial: AudioDeviceID(0))) ?? []
        return ids.compactMap { id in
            guard let uid = CoreAudio.readString(id, kAudioDevicePropertyDeviceUID) else { return nil }
            // Skip our own private aggregate devices if they ever leak into the list.
            if uid.hasPrefix(AggregateDevice.uidPrefix) { return nil }
            let name = CoreAudio.readString(id, kAudioObjectPropertyName) ?? "Device \(id)"
            let inputs = CoreAudio.channelCount(id, scope: kAudioObjectPropertyScopeInput)
            let outputs = CoreAudio.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            guard inputs > 0 || outputs > 0 else { return nil }
            return AudioDevice(id: id, uid: uid, name: name, inputChannels: inputs, outputChannels: outputs)
        }
    }

    func inputDevices() -> [AudioDevice] { allDevices().filter(\.hasInput) }
    func outputDevices() -> [AudioDevice] { allDevices().filter(\.hasOutput) }

    func defaultOutputDeviceID() -> AudioDeviceID? {
        let id = (try? CoreAudio.read(CoreAudio.systemObject, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))) ?? 0
        return id == 0 ? nil : id
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        let id = (try? CoreAudio.read(CoreAudio.systemObject, kAudioHardwarePropertyDefaultInputDevice, initial: AudioDeviceID(0))) ?? 0
        return id == 0 ? nil : id
    }

    private func startListening() {
        guard !listenerInstalled else { return }
        listenerInstalled = true
        snapshot = currentSnapshot()
        let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice]
        for selector in selectors {
            var addr = CoreAudio.address(selector)
            AudioObjectAddPropertyListenerBlock(CoreAudio.systemObject, &addr, DispatchQueue.main) { [weak self] _, _ in
                guard let self else { return }
                // Creating our own aggregate device fires this too; only notify on real changes.
                let now = self.currentSnapshot()
                guard now != self.snapshot else { return }
                self.snapshot = now
                for observer in self.observers { observer() }
            }
        }
    }
}
