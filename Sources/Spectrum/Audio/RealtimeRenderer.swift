import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import os

/// Bridges a Core Audio device IOProc with an AVAudioEngine running in realtime manual-rendering mode.
/// Everything in `process` runs on the HAL's realtime thread: no allocation, no Swift collections being resized.
final class RealtimeRenderer {
    let format: AVAudioFormat
    let maxFrames: Int
    let clock: TransportClock

    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var renderBlock: AVAudioEngineManualRenderingBlock?
    private var ready = false
    private let peaks: UnsafeMutablePointer<Float>   // [left, right]
    private let overloads: UnsafeMutablePointer<UInt32>
    private let stats: UnsafeMutablePointer<UInt32>  // [callbacks, inputChannels, outputChannels, frames]
    private var tonePhase: Double = 0
    /// Diagnostics only: when > 0, the device input is replaced by a sine at this amplitude.
    var testToneAmplitude: Float = 0

    init(format: AVAudioFormat, maxFrames: Int, clock: TransportClock) {
        self.format = format
        self.maxFrames = maxFrames
        self.clock = clock
        inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxFrames))!
        outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxFrames))!
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        peaks = .allocate(capacity: 2)
        peaks.initialize(repeating: 0, count: 2)
        overloads = .allocate(capacity: 1)
        overloads.initialize(to: 0)
        stats = .allocate(capacity: 4)
        stats.initialize(repeating: 0, count: 4)
    }

    deinit {
        lock.deallocate()
        peaks.deallocate()
        overloads.deallocate()
        stats.deallocate()
    }

    /// (callbacks, input channels, output channels, frames per callback) seen so far.
    var statistics: (UInt32, UInt32, UInt32, UInt32) { (stats[0], stats[1], stats[2], stats[3]) }

    // MARK: Control (main thread)

    /// Hands the engine's render block to the realtime side. Pass nil to output silence.
    func setRenderBlock(_ block: AVAudioEngineManualRenderingBlock?) {
        os_unfair_lock_lock(lock)
        renderBlock = block
        ready = block != nil
        os_unfair_lock_unlock(lock)
    }

    /// Used by AVAudioInputNode.setManualRenderingInputPCMFormat to pull the current input chunk.
    func inputList(for frameCount: AVAudioFrameCount) -> UnsafePointer<AudioBufferList>? {
        UnsafePointer(inputBuffer.audioBufferList)
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

    // MARK: Realtime path

    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        // Frame count comes from the output side (same clock for the whole aggregate device).
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

        // Start from silence on every output channel.
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
            let rendered = render(frames: frames)
            if rendered { scatterOutput(outList, offset: offset, frames: frames) }
            offset += frames
        }
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
        // Mono source: feed both ears.
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

    private func render(frames: Int) -> Bool {
        guard os_unfair_lock_trylock(lock) else { return false }
        defer { os_unfair_lock_unlock(lock) }
        guard ready, let renderBlock else { return false }

        outputBuffer.frameLength = AVAudioFrameCount(frames)
        var error: OSStatus = noErr
        let status = renderBlock(AVAudioFrameCount(frames), outputBuffer.mutableAudioBufferList, &error)
        guard status == .success, let data = outputBuffer.floatChannelData else {
            if status == .insufficientDataFromInputNode || status == .error { overloads.pointee &+= 1 }
            return false
        }
        clock.advance(by: frames)
        var peak: Float = 0
        vDSP_maxmgv(data[0], 1, &peak, vDSP_Length(frames))
        if peak > peaks[0] { peaks[0] = peak }
        vDSP_maxmgv(data[1], 1, &peak, vDSP_Length(frames))
        if peak > peaks[1] { peaks[1] = peak }
        return true
    }

    private func scatterOutput(_ list: UnsafeMutableAudioBufferListPointer, offset: Int, frames: Int) {
        guard let source = outputBuffer.floatChannelData else { return }
        var global = 0
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            let available = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            guard offset < available else { global += channels; continue }
            let count = min(frames, available - offset)
            let dest = data.assumingMemoryBound(to: Float.self) + offset * channels
            for channel in 0..<channels {
                if global < 2 {
                    let from = source[global]
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
