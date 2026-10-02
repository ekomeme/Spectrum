import AudioToolbox
import AVFoundation
import Foundation

/// Tells hosted plugins that the "transport" is always playing, with a real running sample position
/// and a fixed tempo. Analysers like MetricAB freeze their displays unless the host reports playback.
final class TransportClock {
    static let tempo: Float64 = 120
    static let beatsPerBar: Float64 = 4

    private let position: UnsafeMutablePointer<Int64>
    private let playingFlag: UnsafeMutablePointer<UInt8>
    private let rate: UnsafeMutablePointer<Float64>
    /// Diagnostics: [v3 transport, v3 musical, v2 transport, v2 beatTempo, v2 timeLocation]
    private let calls: UnsafeMutablePointer<UInt32>

    var callCounts: [UInt32] { (0..<5).map { calls[$0] } }

    init() {
        calls = .allocate(capacity: 5)
        calls.initialize(repeating: 0, count: 5)
        position = .allocate(capacity: 1)
        position.initialize(to: 0)
        playingFlag = .allocate(capacity: 1)
        playingFlag.initialize(to: 0)
        rate = .allocate(capacity: 1)
        rate.initialize(to: 48_000)
    }

    deinit {
        position.deallocate()
        playingFlag.deallocate()
        rate.deallocate()
        calls.deallocate()
    }

    var sampleRate: Float64 {
        get { rate.pointee }
        set { rate.pointee = newValue }
    }

    var isPlaying: Bool {
        get { playingFlag.pointee != 0 }
        set { playingFlag.pointee = newValue ? 1 : 0 }
    }

    var samplePosition: Int64 { position.pointee }

    func reset() { position.pointee = 0 }

    /// Called from the realtime thread after each rendered block.
    func advance(by frames: Int) { position.pointee &+= Int64(frames) }

    private var currentBeat: Float64 {
        Float64(position.pointee) / rate.pointee * (Self.tempo / 60)
    }

    // MARK: - Install on a plugin

    func install(on unit: AVAudioUnit) {
        installV3Blocks(on: unit.auAudioUnit)
        installV2HostCallbacks(on: unit.audioUnit)
    }

    private func installV3Blocks(on au: AUAudioUnit) {
        au.transportStateBlock = { [self] flags, currentSamplePosition, cycleStart, cycleEnd in
            calls[0] &+= 1
            flags?.pointee = isPlaying ? [.moving] : []
            currentSamplePosition?.pointee = Float64(position.pointee)
            cycleStart?.pointee = 0
            cycleEnd?.pointee = 0
            return true
        }
        au.musicalContextBlock = { [self] tempo, numerator, denominator, beat, sampleOffset, measureBeat in
            calls[1] &+= 1
            tempo?.pointee = Self.tempo
            numerator?.pointee = Self.beatsPerBar
            denominator?.pointee = 4
            let current = currentBeat
            beat?.pointee = current
            sampleOffset?.pointee = 0
            measureBeat?.pointee = floor(current / Self.beatsPerBar) * Self.beatsPerBar
            return true
        }
    }

    private func installV2HostCallbacks(on audioUnit: AudioUnit) {
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var info = HostCallbackInfo(
            hostUserData: userData,
            beatAndTempoProc: { userData, outBeat, outTempo in
                guard let userData else { return OSStatus(kAudioUnitErr_CannotDoInCurrentContext) }
                let clock = Unmanaged<TransportClock>.fromOpaque(userData).takeUnretainedValue()
                clock.calls[3] &+= 1
                outBeat?.pointee = clock.currentBeat
                outTempo?.pointee = TransportClock.tempo
                return noErr
            },
            musicalTimeLocationProc: { userData, outDeltaToNextBeat, outNumerator, outDenominator, outDownBeat in
                guard let userData else { return OSStatus(kAudioUnitErr_CannotDoInCurrentContext) }
                let clock = Unmanaged<TransportClock>.fromOpaque(userData).takeUnretainedValue()
                clock.calls[4] &+= 1
                let beat = clock.currentBeat
                let samplesPerBeat = clock.rate.pointee * 60 / TransportClock.tempo
                outDeltaToNextBeat?.pointee = UInt32((ceil(beat) - beat) * samplesPerBeat)
                outNumerator?.pointee = Float32(TransportClock.beatsPerBar)
                outDenominator?.pointee = 4
                outDownBeat?.pointee = floor(beat / TransportClock.beatsPerBar) * TransportClock.beatsPerBar
                return noErr
            },
            transportStateProc: { userData, outIsPlaying, outChanged, outSample, outIsCycling, outCycleStart, outCycleEnd in
                guard let userData else { return OSStatus(kAudioUnitErr_CannotDoInCurrentContext) }
                let clock = Unmanaged<TransportClock>.fromOpaque(userData).takeUnretainedValue()
                clock.calls[2] &+= 1
                outIsPlaying?.pointee = DarwinBoolean(clock.isPlaying)
                outChanged?.pointee = false
                outSample?.pointee = Float64(clock.position.pointee)
                outIsCycling?.pointee = false
                outCycleStart?.pointee = 0
                outCycleEnd?.pointee = 0
                return noErr
            },
            transportStateProc2: nil
        )
        AudioUnitSetProperty(audioUnit, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0,
                             &info, UInt32(MemoryLayout<HostCallbackInfo>.size))
    }

    /// Diagnostics: is our HostCallbackInfo still what the v2 AU holds?
    func hostCallbacksInstalled(on audioUnit: AudioUnit) -> Bool {
        var info = HostCallbackInfo()
        var size = UInt32(MemoryLayout<HostCallbackInfo>.size)
        let status = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &info, &size)
        return status == noErr && info.hostUserData == Unmanaged.passUnretained(self).toOpaque()
    }
}
