import AVFoundation
import Foundation

/// Lists the Audio Unit effects installed on this Mac.
enum PluginCatalog {
    static func effects() -> [AVAudioUnitComponent] {
        let manager = AVAudioUnitComponentManager.shared()
        var seen = Set<String>()
        var result: [AVAudioUnitComponent] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            var description = AudioComponentDescription()
            description.componentType = type
            for component in manager.components(matching: description) {
                let key = Self.key(for: component.audioComponentDescription)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(component)
            }
        }
        return result.sorted {
            let lhs = ($0.manufacturerName.lowercased(), $0.name.lowercased())
            let rhs = ($1.manufacturerName.lowercased(), $1.name.lowercased())
            return lhs < rhs
        }
    }

    static func component(matching description: AudioComponentDescription) -> AVAudioUnitComponent? {
        var query = description
        query.componentFlags = 0
        query.componentFlagsMask = 0
        return AVAudioUnitComponentManager.shared().components(matching: query).first
    }

    static func key(for description: AudioComponentDescription) -> String {
        "\(description.componentType)-\(description.componentSubType)-\(description.componentManufacturer)"
    }
}
