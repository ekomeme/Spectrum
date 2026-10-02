import CoreAudio
import Foundation

/// Captures the mix of every other process's output using a Core Audio process tap (macOS 14.2+).
/// Our own process is excluded so the processed signal we play back is never re-captured.
final class SystemAudioTap {
    let tapID: AudioObjectID
    let uuid: UUID

    init(muteOriginal: Bool) throws {
        var excluded: [AudioObjectID] = []
        if let me = CoreAudio.currentProcessObjectID() {
            excluded.append(me)
        } else {
            throw CoreAudioError.message("Could not identify Spectrum's own process to exclude it from the capture.")
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Spectrum System Tap"
        description.isPrivate = true
        description.muteBehavior = muteOriginal ? .mutedWhenTapped : .unmuted

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw CoreAudioError.status(status, "Could not create the system audio capture. Check the permission in System Settings → Privacy & Security → Screen & System Audio Recording")
        }
        tapID = id
        uuid = description.uuid
    }

    func destroy() {
        AudioHardwareDestroyProcessTap(tapID)
    }
}

/// A private aggregate device that bundles the chosen output device, an optional hardware input device
/// and an optional system tap into a single device the audio engine can use for both input and output.
final class AggregateDevice {
    static let uidPrefix = "design.webake.spectrum.aggregate."

    let id: AudioDeviceID

    init(output: AudioDevice, input: AudioDevice?, tapUUID: UUID?, isPrivate: Bool = true) throws {
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: output.uid]]
        if let input, input.uid != output.uid {
            subDevices.append([kAudioSubDeviceUIDKey: input.uid, kAudioSubDeviceDriftCompensationKey: 1])
        }

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Spectrum Engine",
            kAudioAggregateDeviceUIDKey: Self.uidPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: isPrivate ? 1 : 0,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
        if let tapUUID {
            description[kAudioAggregateDeviceTapAutoStartKey] = 1
            description[kAudioAggregateDeviceTapListKey] = [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: 1,
            ]]
        }

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw CoreAudioError.status(status, "Could not create the aggregate device")
        }
        id = aggregateID
    }

    func setBufferFrameSize(_ frames: UInt32) {
        try? CoreAudio.write(id, kAudioDevicePropertyBufferFrameSize, value: frames)
    }

    var sampleRate: Double {
        (try? CoreAudio.read(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))) ?? 0
    }

    var bufferFrameSize: UInt32 {
        (try? CoreAudio.read(id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0))) ?? 0
    }

    /// Virtual (client-side) stream format of the first stream in the given scope.
    func streamFormat(scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
        try? CoreAudio.read(id, kAudioDevicePropertyStreamFormat, scope: scope, initial: AudioStreamBasicDescription())
    }

    func destroy() {
        AudioHardwareDestroyAggregateDevice(id)
    }
}

extension AudioStreamBasicDescription {
    var isFloat32: Bool {
        mFormatID == kAudioFormatLinearPCM && (mFormatFlags & kAudioFormatFlagIsFloat) != 0 && mBitsPerChannel == 32
    }
}
