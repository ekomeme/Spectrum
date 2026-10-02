import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

/// Shared between the renderer and every plugin's v2 render callback: where the current input lives.
/// One instance lives for the whole app, so plugins keep their callback across engine restarts.
final class InputFeed {
    fileprivate let current: UnsafeMutablePointer<UnsafeMutablePointer<AudioBufferList>?>

    init() {
        current = .allocate(capacity: 1)
        current.initialize(to: nil)
    }

    deinit { current.deallocate() }

    var opaque: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// Classic AU render callback: points the plugin at the previous stage's buffers.
    static let renderCallback: AURenderCallback = { refCon, _, _, _, frameCount, data in
        let feed = Unmanaged<InputFeed>.fromOpaque(refCon).takeUnretainedValue()
        guard let data, let source = feed.current.pointee else { return OSStatus(kAudioUnitErr_NoConnection) }
        let destination = UnsafeMutableAudioBufferListPointer(data)
        let origin = UnsafeMutableAudioBufferListPointer(source)
        let bytes = Int(frameCount) * MemoryLayout<Float>.size
        for index in 0..<min(destination.count, origin.count) {
            guard let from = origin[index].mData else { continue }
            if let to = destination[index].mData, to != from {
                memcpy(to, from, min(bytes, Int(origin[index].mDataByteSize)))
            } else {
                destination[index].mData = from
            }
            destination[index].mDataByteSize = UInt32(bytes)
            destination[index].mNumberChannels = 1
        }
        return noErr
    }
}

/// Renders the plugin chain directly from a Core Audio device IOProc, the way a DAW does:
/// each plugin is rendered in series through the classic AudioUnitRender API with the device's real timestamp.
/// Everything in `process` runs on the HAL's realtime thread: no allocation, no Swift collections being resized.
final class RealtimeRenderer {
    struct Stage {
        let id: UUID
        let audioUnit: AudioUnit
    }

    let format: AVAudioFormat
    let maxFrames: Int
    let clock: TransportClock
    let feed: InputFeed

    private let inputBuffer: AVAudioPCMBuffer
    private let bufferA: AVAudioPCMBuffer
    private let bufferB: AVAudioPCMBuffer
    private let listA: UnsafeMutableAudioBufferListPointer
    private let listB: UnsafeMutableAudioBufferListPointer
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var chain: [Stage] = []
    private let peaks: UnsafeMutablePointer<Float>   // [left, right]
    private let overloads: UnsafeMutablePointer<UInt32>
    private let firstError: UnsafeMutablePointer<OSStatus>
    private let stats: UnsafeMutablePointer<UInt32>  // [callbacks, inputChannels, outputChannels, frames]
    private var timebase = mach_timebase_info()
    private var tonePhase: Double = 0
    /// Diagnostics only: when > 0, the device input is replaced by a sine at this amplitude.
    var testToneAmplitude: Float = 0

    init(format: AVAudioFormat, maxFrames: Int, clock: TransportClock, feed: InputFeed) {
        self.format = format
        self.maxFrames = maxFrames
        self.clock = clock
        self.feed = feed
        inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxFrames))!
        bufferA = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxFrames))!
        bufferB = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxFrames))!
        listA = AudioBufferList.allocate(maximumBuffers: 2)
        listB = AudioBufferList.allocate(maximumBuffers: 2)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        peaks = .allocate(capacity: 2)
        peaks.initialize(repeating: 0, count: 2)
        overloads = .allocate(capacity: 1)
        overloads.initialize(to: 0)
        firstError = .allocate(capacity: 1)
        firstError.initialize(to: noErr)
        stats = .allocate(capacity: 4)
        stats.initialize(repeating: 0, count: 4)
        mach_timebase_info(&timebase)
    }

    deinit {
        free(listA.unsafeMutablePointer)
        free(listB.unsafeMutablePointer)
        lock.deallocate()
        peaks.deallocate()
        overloads.deallocate()
        firstError.deallocate()
        stats.deallocate()
    }

    // MARK: Control (main thread)

    /// Replaces the plugin chain atomically. The realtime thread skips one block if it collides with the swap.
    func setChain(_ stages: [Stage]) {
        os_unfair_lock_lock(lock)
        chain = stages
        os_unfair_lock_unlock(lock)
    }

    /// Peak level since last call (0…1 linear), reset on read.
    func takePeaks() -> (Float, Float) {
        let left = peaks[0]
        let right = peaks[1]
        peaks[0] = 0
        peaks[1] = 0
        return (left, right)
    }

    var overloadCount: UInt32 { overloads.pointee }
    var firstErrorStatus: OSStatus { firstError.pointee }

    /// (callbacks, input channels, output channels, frames per callback) seen so far.
    var statistics: (UInt32, UInt32, UInt32, UInt32) { (stats[0], stats[1], stats[2], stats[3]) }

    // MARK: Realtime path

    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                 timestamp: UnsafePointer<AudioTimeStamp>) {
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        var totalFrames = 0
        for buffer in outList where buffer.mNumberChannels > 0 {
            totalFrames = Int(buffer.mDataByteSize) / (Int(buffer.mNumberChannels) * MemoryLayout<Float>.size)
            break
        }
        if totalFrames == 0 {
            for buffer in inList where buffer.mNumberChannels > 0 {
                totalFrames = Int(buffer.mDataByteSize) / (Int(buffer.mNumberChannels) * MemoryLayout<Float>.size)
                break
            }
        }
        guard totalFrames > 0 else { return }
        stats[0] &+= 1
        stats[1] = inList.reduce(0) { $0 + $1.mNumberChannels }
        stats[2] = outList.reduce(0) { $0 + $1.mNumberChannels }
        stats[3] = UInt32(totalFrames)

        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        var offset = 0
        while offset < totalFrames {
            let frames = min(maxFrames, totalFrames - offset)
            if testToneAmplitude > 0 {
                fillTestTone(frames: frames)
            } else {
                gatherInput(inList, offset: offset, frames: frames)
            }
            if let result = renderChain(frames: frames, offset: offset, timestamp: timestamp) {
                scatterOutput(outList, from: result, offset: offset, frames: frames)
            }
            offset += frames
        }
    }

    private func renderChain(frames: Int, offset: Int, timestamp: UnsafePointer<AudioTimeStamp>) -> UnsafeMutablePointer<AudioBufferList>? {
        guard os_unfair_lock_trylock(lock) else { return nil }
        defer { os_unfair_lock_unlock(lock) }

        var stamp = timestamp.pointee
        if offset > 0 {
            stamp.mSampleTime += Double(offset)
            if stamp.mFlags.contains(.hostTimeValid), timebase.numer > 0 {
                let nanos = Double(offset) / format.sampleRate * 1_000_000_000
                stamp.mHostTime &+= UInt64(nanos * Double(timebase.denom) / Double(timebase.numer))
            }
        }

        var source = inputBuffer.mutableAudioBufferList
        var useA = true
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        for stage in chain {
            let list = useA ? listA : listB
            let buffer = useA ? bufferA : bufferB
            guard let channels = buffer.floatChannelData else { break }
            list.count = 2
            for channel in 0..<2 {
                list[channel].mNumberChannels = 1
                list[channel].mDataByteSize = bytes
                list[channel].mData = UnsafeMutableRawPointer(channels[channel])
            }
            feed.current.pointee = source
            var flags = AudioUnitRenderActionFlags()
            let status = AudioUnitRender(stage.audioUnit, &flags, &stamp, 0, UInt32(frames), list.unsafeMutablePointer)
            if status != noErr {
                overloads.pointee &+= 1
                if firstError.pointee == noErr { firstError.pointee = status }
                // Pass the signal through untouched rather than dropping out.
                let origin = UnsafeMutableAudioBufferListPointer(source)
                for channel in 0..<min(2, origin.count) {
                    if let from = origin[channel].mData, let to = list[channel].mData, from != to {
                        memcpy(to, from, Int(bytes))
                    }
                }
            }
            source = list.unsafeMutablePointer
            useA.toggle()
        }
        feed.current.pointee = nil

        let result = UnsafeMutableAudioBufferListPointer(source)
        var peak: Float = 0
        for channel in 0..<min(2, result.count) {
            guard let data = result[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            vDSP_maxmgv(data, 1, &peak, vDSP_Length(frames))
            if peak > peaks[channel] { peaks[channel] = peak }
        }
        clock.advance(by: frames)
        return source
    }

    private func gatherInput(_ list: UnsafeMutableAudioBufferListPointer, offset: Int, frames: Int) {
        guard let dest = inputBuffer.floatChannelData else { return }
        let n = vDSP_Length(frames)
        vDSP_vclr(dest[0], 1, n)
        vDSP_vclr(dest[1], 1, n)
        inputBuffer.frameLength = AVAudioFrameCount(frames)

        var global = 0
        var copied = 0
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            let available = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            guard offset < available else { global += channels; continue }
            let count = min(frames, available - offset)
            let source = data.assumingMemoryBound(to: Float.self) + offset * channels
            for channel in 0..<channels {
                if global < 2 {
                    let target = dest[global]
                    var index = channel
                    for frame in 0..<count {
                        target[frame] = source[index]
                        index += channels
                    }
                    copied += 1
                }
                global += 1
            }
            if global >= 2 { break }
        }
        if copied == 1 {
            memcpy(dest[1], dest[0], frames * MemoryLayout<Float>.size)
        }
    }

    private func fillTestTone(frames: Int) {
        guard let dest = inputBuffer.floatChannelData else { return }
        let step = 2 * Double.pi * 440 / format.sampleRate
        for frame in 0..<frames {
            let sample = Float(sin(tonePhase)) * testToneAmplitude
            dest[0][frame] = sample
            dest[1][frame] = sample
            tonePhase += step
            if tonePhase > 2 * Double.pi { tonePhase -= 2 * Double.pi }
        }
        inputBuffer.frameLength = AVAudioFrameCount(frames)
    }

    private func scatterOutput(_ list: UnsafeMutableAudioBufferListPointer, from source: UnsafeMutablePointer<AudioBufferList>,
                               offset: Int, frames: Int) {
        let origin = UnsafeMutableAudioBufferListPointer(source)
        var global = 0
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            let available = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            guard offset < available else { global += channels; continue }
            let count = min(frames, available - offset)
            let dest = data.assumingMemoryBound(to: Float.self) + offset * channels
            for channel in 0..<channels {
                if global < 2, global < origin.count, let from = origin[global].mData?.assumingMemoryBound(to: Float.self) {
                    var index = channel
                    for frame in 0..<count {
                        dest[index] = from[frame]
                        index += channels
                    }
                }
                global += 1
            }
            if global >= 2 { break }
        }
    }
}
