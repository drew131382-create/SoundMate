import AudioToolbox
import Foundation

/// Float32 channel mapping for a stereo tap and planar/interleaved hardware.
/// No allocation, locking or property queries on the real-time path.
enum AudioBufferRenderer {
    static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        tapChannels: Int,
        targetVolume: Float,
        currentVolume: inout Float,
        rampCoefficient: Float,
        muted: Bool
    ) -> Bool {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard !outputs.isEmpty else { return false }
        if muted { return true }
        // Aggregate input streams include hardware inputs before the tap.
        var firstInput = inputs.count
        var channels = 0
        while firstInput > 0 && channels < tapChannels {
            firstInput -= 1
            channels += Int(inputs[firstInput].mNumberChannels)
        }
        guard channels == tapChannels, tapChannels > 0 else { return false }
        var frames = Int.max
        for index in firstInput..<inputs.count {
            let buffer = inputs[index]
            let channelCount = Int(buffer.mNumberChannels)
            guard channelCount > 0, buffer.mData != nil,
                  Int(buffer.mDataByteSize) % (channelCount * MemoryLayout<Float>.size) == 0 else { return false }
            frames = min(frames, Int(buffer.mDataByteSize) / (channelCount * MemoryLayout<Float>.size))
        }
        var outputChannels = 0
        for buffer in outputs {
            let channelCount = Int(buffer.mNumberChannels)
            guard channelCount > 0, buffer.mData != nil,
                  Int(buffer.mDataByteSize) % (channelCount * MemoryLayout<Float>.size) == 0 else { return false }
            outputChannels += channelCount
            frames = min(frames, Int(buffer.mDataByteSize) / (channelCount * MemoryLayout<Float>.size))
        }
        guard outputChannels > 0, frames > 0, frames != Int.max else { return false }
        for frame in 0..<frames {
            currentVolume += (targetVolume - currentVolume) * rampCoefficient
            var outputChannel = 0
            for buffer in outputs {
                let count = Int(buffer.mNumberChannels)
                let destination = buffer.mData!.assumingMemoryBound(to: Float.self)
                for channel in 0..<count {
                    defer { outputChannel += 1 }
                    guard outputChannel < tapChannels else { continue }
                    // Bluetooth call mode can expose a mono output stream.
                    let firstChannel = outputChannels == 1 ? 0 : outputChannel
                    let channelsToMix = outputChannels == 1 ? tapChannels : 1
                    var sample: Float = 0
                    for mixedChannel in firstChannel..<(firstChannel + channelsToMix) {
                        var sourceChannel = mixedChannel
                        for index in firstInput..<inputs.count {
                            let source = inputs[index]
                            let sourceChannels = Int(source.mNumberChannels)
                            if sourceChannel < sourceChannels {
                                let samples = source.mData!.assumingMemoryBound(to: Float.self)
                                sample += samples[frame * sourceChannels + sourceChannel]
                                break
                            }
                            sourceChannel -= sourceChannels
                        }
                    }
                    destination[frame * count + channel] = renderSample(sample / Float(channelsToMix), gain: currentVolume)
                }
            }
        }
        return true
    }

    static func supports(_ format: AudioStreamBasicDescription) -> Bool {
        let channelsPerBuffer = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : format.mChannelsPerFrame
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && format.mBitsPerChannel == 32
            && format.mChannelsPerFrame > 0
            && format.mBytesPerFrame == channelsPerBuffer * UInt32(MemoryLayout<Float>.size)
            && format.mSampleRate.isFinite && format.mSampleRate > 0
    }

    static func renderSample(_ sample: Float, gain: Float) -> Float {
        let scaled = sample * gain
        guard gain > 1 else { return scaled }
        let magnitude = abs(scaled)
        let threshold: Float = 0.8
        guard magnitude > threshold else { return scaled }
        let overshoot = magnitude - threshold
        let headroom: Float = 0.2
        let compressed = threshold + headroom * (overshoot / (overshoot + headroom))
        return scaled >= 0 ? compressed : -compressed
    }
}
