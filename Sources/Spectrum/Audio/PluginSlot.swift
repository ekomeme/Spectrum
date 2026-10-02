import AVFoundation
import Foundation

/// One loaded Audio Unit in the processing chain.
final class PluginSlot {
    let id = UUID()
    let name: String
    let manufacturer: String
    let description: AudioComponentDescription
    let unit: AVAudioUnit
    let supportsStereo: Bool
    var windowController: PluginWindowController?
    /// Sample rate the render resources were allocated for (0 = not allocated).
    var preparedSampleRate: Double = 0

    init(unit: AVAudioUnit, name: String, manufacturer: String, processFormat: AVAudioFormat) {
        self.unit = unit
        self.name = name
        self.manufacturer = manufacturer
        self.description = unit.audioComponentDescription
        self.supportsStereo = Self.check(unit: unit, format: processFormat)
    }

    var bypassed: Bool {
        get {
            var value: UInt32 = 0
            var size: UInt32 = 4
            let status = AudioUnitGetProperty(unit.audioUnit, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &value, &size)
            return status == noErr ? value != 0 : unit.auAudioUnit.shouldBypassEffect
        }
        set {
            var value: UInt32 = newValue ? 1 : 0
            AudioUnitSetProperty(unit.audioUnit, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &value, 4)
            unit.auAudioUnit.shouldBypassEffect = newValue
        }
    }

    var displayName: String { "\(manufacturer) – \(name)" }

    /// Verify the plugin accepts the stereo processing format before it is wired into the graph.
    /// AVAudioEngine.connect raises an Objective‑C exception on incompatible formats, which Swift cannot catch.
    private static func check(unit: AVAudioUnit, format: AVAudioFormat) -> Bool {
        let au = unit.auAudioUnit
        guard au.inputBusses.count > 0, au.outputBusses.count > 0 else { return false }
        do {
            try au.inputBusses[0].setFormat(format)
            try au.outputBusses[0].setFormat(format)
            return true
        } catch {
            return false
        }
    }

    func savedState() -> SavedPlugin {
        var data: Data? = nil
        if let state = unit.auAudioUnit.fullState {
            data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        }
        return SavedPlugin(type: description.componentType,
                           subType: description.componentSubType,
                           manufacturer: description.componentManufacturer,
                           name: name,
                           manufacturerName: manufacturer,
                           state: data,
                           bypassed: bypassed)
    }

    func restore(state data: Data?) {
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else { return }
        unit.auAudioUnit.fullState = dict
    }
}

struct SavedPlugin: Codable {
    var type: UInt32
    var subType: UInt32
    var manufacturer: UInt32
    var name: String
    var manufacturerName: String
    var state: Data?
    var bypassed: Bool

    var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subType, componentManufacturer: manufacturer,
                                  componentFlags: 0, componentFlagsMask: 0)
    }
}

struct EngineSettings: Codable {
    /// nil means "system audio" (Core Audio tap); otherwise the UID of a hardware input device.
    var sourceDeviceUID: String? = nil
    var outputDeviceUID: String? = nil
    var bufferSize: UInt32 = 256
    var muteOriginal: Bool = true
}

struct Session: Codable {
    var settings = EngineSettings()
    var plugins: [SavedPlugin] = []
    var wasRunning = false
}
