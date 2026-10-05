import AudioToolbox
import Foundation

private final class Buffers {
    let list: UnsafeMutablePointer<AudioBufferList>
    let allocations: [UnsafeMutablePointer<Float>]

    init(_ values: [(channels: Int, samples: [Float])]) {
        list = AudioBufferList.allocate(maximumBuffers: values.count).unsafeMutablePointer
        list.pointee.mNumberBuffers = UInt32(values.count)
        var allocated: [UnsafeMutablePointer<Float>] = []
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for (index, value) in values.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: value.samples.count)
            data.initialize(from: value.samples, count: value.samples.count)
            allocated.append(data)
            buffers[index] = AudioBuffer(mNumberChannels: UInt32(value.channels),
                mDataByteSize: UInt32(value.samples.count * MemoryLayout<Float>.size), mData: data)
        }
        allocations = allocated
    }
    deinit {
        allocations.forEach { $0.deallocate() }
        list.deallocate()
    }
    func samples(_ index: Int) -> [Float] {
        let buffer = UnsafeMutableAudioBufferListPointer(list)[index]
        return Array(UnsafeBufferPointer(start: buffer.mData!.assumingMemoryBound(to: Float.self),
            count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
    }
}

@main
enum AudioBufferRendererTests {
    static func main() {
        let stereo: [Float] = [0.1, -0.2, 0.3, -0.4, 0.5, -0.6]
        do {
            let source = Buffers([(2, stereo)])
            let destination = Buffers([(1, [9, 9, 9, 9]), (1, [9, 9, 9, 9])])
            var gain: Float = 1
            precondition(AudioBufferRenderer.render(input: source.list, output: destination.list,
                tapChannels: 2, targetVolume: 1, currentVolume: &gain, rampCoefficient: 1, muted: false))
            precondition(destination.samples(0) == [0.1, 0.3, 0.5, 0])
            precondition(destination.samples(1) == [-0.2, -0.4, -0.6, 0])
        }
        do {
            let source = Buffers([(1, [99, 99, 99]), (1, [0.1, 0.3, 0.5]), (1, [-0.2, -0.4, -0.6])])
            let destination = Buffers([(2, Array(repeating: 9, count: 6))])
            var gain: Float = 0.5
            precondition(AudioBufferRenderer.render(input: source.list, output: destination.list,
                tapChannels: 2, targetVolume: 0.5, currentVolume: &gain, rampCoefficient: 1, muted: false))
            precondition(destination.samples(0) == stereo.map { $0 * 0.5 })
        }
        do {
            let source = Buffers([(2, [0.2, 0.4, -0.2, -0.4])])
            let destination = Buffers([(1, [9, 9])])
            var gain: Float = 1
            precondition(AudioBufferRenderer.render(input: source.list, output: destination.list,
                tapChannels: 2, targetVolume: 1, currentVolume: &gain, rampCoefficient: 1, muted: false))
            precondition(destination.samples(0) == [0.3, -0.3])
        }
        do {
            let source = Buffers([(1, [0.1, 0.2])])
            let destination = Buffers([(2, [9, 9, 9, 9])])
            var gain: Float = 1
            precondition(!AudioBufferRenderer.render(input: source.list, output: destination.list,
                tapChannels: 2, targetVolume: 1, currentVolume: &gain, rampCoefficient: 1, muted: false))
            precondition(destination.samples(0) == [0, 0, 0, 0])
        }
        do {
            let source = Buffers([(2, stereo)])
            let destination = Buffers([(2, Array(repeating: 9, count: 6))])
            var gain: Float = 1
            precondition(AudioBufferRenderer.render(input: source.list, output: destination.list,
                tapChannels: 2, targetVolume: 1, currentVolume: &gain, rampCoefficient: 1, muted: true))
            precondition(destination.samples(0).allSatisfy { $0 == 0 })
            precondition(AudioBufferRenderer.render(input: source.list, output: destination.list,
                tapChannels: 2, targetVolume: 0, currentVolume: &gain, rampCoefficient: 1, muted: false))
            precondition(destination.samples(0).allSatisfy { $0 == 0 })
        }
        for sample in -10000...10000 {
            let value = Float(sample) / 10000
            precondition(AudioBufferRenderer.renderSample(value, gain: 1) == value)
            precondition(AudioBufferRenderer.renderSample(value, gain: 0.15) == value * 0.15)
            precondition(abs(AudioBufferRenderer.renderSample(value, gain: 3)) <= 1)
        }
        print("PASS: stereo/planar/mono conversion, hardware input exclusion, zeroed tails, mute and 20,001 signal samples")
    }
}
