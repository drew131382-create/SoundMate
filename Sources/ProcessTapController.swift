import AudioToolbox
import Foundation
import os

/// Controls audio processing for a single app via CoreAudio process tap.
/// Uses an aggregate device with an IO callback for real-time volume/mute control.
@available(macOS 14.2, *)
final class ProcessTapController: AudioRouteTap {
    let pid: pid_t
    let processObjectID: AudioObjectID
    private let logger: Logger
    private let queue = DispatchQueue(label: "ProcessTapController", qos: .userInitiated)

    // MARK: - RT-Safe State

    /// Target volume set by user (0.0-3.0, where 1.0 = unity gain)
    private nonisolated(unsafe) var _volume: Float = 1.0
    /// Current ramped volume (smoothly approaches _volume)
    private nonisolated(unsafe) var _currentVolume: Float = 1.0
    /// User-controlled mute - outputs silence
    private nonisolated(unsafe) var _isMuted: Bool = false
    /// Updated only by the serial I/O callback queue.
    private var callbackCount: UInt64 = 0
    private var validBufferCount: UInt64 = 0
    private var requestedVolume: Float = 1
    private var requestedMute = false
    private var tapChannels = 2
    private var topologyListeners: [(AudioObjectID, AudioObjectPropertyAddress, DispatchQueue, AudioObjectPropertyListenerBlock)] = []

    // MARK: - Non-RT State

    /// Volume ramp coefficient (30ms ramp at 48kHz prevents clicks)
    private var rampCoefficient: Float = 0.0007

    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var activated = false
    private var outputDeviceID: AudioObjectID = .unknown
    private var lastDuckingResult: String?

    // MARK: - Public Properties

    var volume: Float {
        get { requestedVolume }
        set {
            requestedVolume = max(0, min(3.0, newValue))
            updateMuteBehavior()
            let value = requestedVolume
            queue.async { [weak self] in self?._volume = value }
        }
    }

    var isMuted: Bool {
        get { requestedMute }
        set {
            requestedMute = newValue
            updateMuteBehavior()
            queue.async { [weak self] in self?._isMuted = newValue }
        }
    }

    var isSourceOutputting: Bool? {
        guard (try? processObjectID.readProcessPID()) == pid else { return nil }
        return try? processObjectID.readBool(kAudioProcessPropertyIsRunningOutput)
    }

    func readHealth(_ completion: @escaping (AudioRouteHealth) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            completion(AudioRouteHealth(callbacks: self.callbackCount, validBuffers: self.validBufferCount))
        }
    }

    // MARK: - Initialization

    init?(pid: pid_t, processObjectID candidate: AudioObjectID? = nil) {
        guard let processObjectID = candidate ?? Self.findProcessObjectID(for: pid),
              (try? processObjectID.readProcessPID()) == pid else {
            return nil
        }

        self.pid = pid
        self.processObjectID = processObjectID
        self.logger = Logger(subsystem: "SoundMate", category: "ProcessTapController(\(pid))")
    }

    deinit {
        invalidate()
    }

    // MARK: - Lifecycle

    func activate() throws {
        guard !activated else { return }

        // CATapDescription produces stereo Float32 interleaved audio from the target process.
        // mutedWhenTapped ensures the app's audio goes through our tap, not directly to output.
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = requestedMute || requestedVolume == 0 ? .muted : .mutedWhenTapped
        self.tapDescription = tapDesc

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap: \(err)"])
        }

        processTapID = tapID
        do {
            let format = try tapID.read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
            guard AudioBufferRenderer.supports(format), format.mChannelsPerFrame == 2 else {
                throw NSError(domain: "ProcessTapController", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unsupported tap format"])
            }
            tapChannels = Int(format.mChannelsPerFrame)
        } catch {
            cleanupPartialActivation()
            throw error
        }

        guard let defaultDeviceUID = getDefaultOutputDeviceUID() else {
            cleanupPartialActivation()
            throw NSError(domain: "ProcessTapController", code: -1, userInfo: [NSLocalizedDescriptionKey: "No default output device"])
        }

        let description = buildAggregateDescription(
            outputUID: defaultDeviceUID,
            tapUUID: tapDesc.uuid,
            name: "SoundMate-\(pid)"
        )

        aggregateDeviceID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device: \(err)"])
        }

        guard aggregateDeviceID.waitUntilReady(timeout: 2.0) else {
            cleanupPartialActivation()
            throw NSError(domain: "ProcessTapController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Aggregate device not ready within timeout"])
        }

        do {
            try validateOutputFormats()
        } catch {
            cleanupPartialActivation()
            throw error
        }

        // Compute ramp coefficient from device sample rate
        let sampleRate: Float64
        if let deviceSampleRate = try? aggregateDeviceID.readNominalSampleRate() {
            sampleRate = deviceSampleRate
        } else {
            sampleRate = 48000
        }
        let rampTimeSeconds: Float = 0.030
        rampCoefficient = 1 - exp(-1 / (Float(sampleRate) * rampTimeSeconds))

        err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else {
                for buffer in UnsafeMutableAudioBufferListPointer(outOutputData) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                return
            }
            self.processAudio(inInputData, to: outOutputData)
        }
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create IO proc: \(err)"])
        }

        queue.sync {
            _volume = requestedVolume
            _currentVolume = requestedVolume
            _isMuted = requestedMute
            callbackCount = 0
            validBufferCount = 0
        }
        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            cleanupPartialActivation()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to start device: \(err)"])
        }

        activated = true
        logger.info("Tap activated for PID \(self.pid)")
    }

    /// Called on the manager's control queue. Finish release before replacement.
    @discardableResult
    func invalidate() -> Bool {
        activated = false
        for (object, address, listenerQueue, block) in topologyListeners {
            var mutableAddress = address
            let status = AudioObjectRemovePropertyListenerBlock(object, &mutableAddress, listenerQueue, block)
            if status != noErr && status != kAudioHardwareBadObjectError {
                logger.error("Listener removal failed object=\(object), status=\(status)")
            }
        }
        topologyListeners.removeAll()
        if let procID = deviceProcID, aggregateDeviceID != .unknown {
            let stop = AudioDeviceStop(aggregateDeviceID, procID)
            let destroy = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            logger.notice("I/O release pid=\(self.pid), stop=\(stop), destroy=\(destroy)")
            if destroy == noErr || destroy == kAudioHardwareBadObjectError { deviceProcID = nil }
        }
        if aggregateDeviceID != .unknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            logger.notice("Aggregate release pid=\(self.pid), status=\(status)")
            if status == noErr || status == kAudioHardwareBadObjectError {
                aggregateDeviceID = .unknown
                deviceProcID = nil
            }
        }
        if processTapID != .unknown {
            let status = AudioHardwareDestroyProcessTap(processTapID)
            logger.notice("Tap release pid=\(self.pid), status=\(status)")
            if status == noErr || status == kAudioHardwareBadObjectError {
                processTapID = .unknown
                tapDescription = nil
            }
        }
        return aggregateDeviceID == .unknown && processTapID == .unknown && deviceProcID == nil
    }

    func watchTopology(on controlQueue: DispatchQueue, changed: @escaping () -> Void) {
        let properties: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (outputDeviceID, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (outputDeviceID, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (outputDeviceID, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
            (processTapID, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal)
        ]
        for (object, selector, scope) in properties {
            addTopologyListener(object: object, selector: selector, scope: scope, queue: controlQueue, changed: changed)
        }
        for stream in outputStreams() {
            addTopologyListener(object: stream, selector: kAudioStreamPropertyVirtualFormat,
                                scope: kAudioObjectPropertyScopeGlobal, queue: controlQueue, changed: changed)
        }
    }

    private func addTopologyListener(object: AudioObjectID, selector: AudioObjectPropertySelector,
                                     scope: AudioObjectPropertyScope, queue: DispatchQueue, changed: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return }
        // Queue the recovery after HAL finishes delivering this notification.
        let block: AudioObjectPropertyListenerBlock = { _, _ in queue.async(execute: changed) }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        if status == noErr { topologyListeners.append((object, address, queue, block)) }
        else { logger.error("Topology listener failed object=\(object), selector=\(selector), status=\(status)") }
    }

    private func updateMuteBehavior() {
        guard activated, let description = tapDescription else { return }
        let desired: CATapMuteBehavior = requestedMute || requestedVolume == 0 ? .muted : .mutedWhenTapped
        guard description.muteBehavior != desired else { return }
        description.muteBehavior = desired
        var reference = description
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafePointer(to: &reference) {
            AudioObjectSetPropertyData(processTapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status != noErr { logger.error("Tap mute behavior change failed pid=\(self.pid), status=\(status)") }
    }

    private func outputStreams() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateDeviceID, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var streams = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(aggregateDeviceID, &address, 0, nil, &size, &streams) == noErr else { return [] }
        return streams
    }

    private func validateOutputFormats() throws {
        let streams = outputStreams()
        guard !streams.isEmpty else { throw NSError(domain: "ProcessTapController", code: -3) }
        for stream in streams {
            let format = try stream.read(kAudioStreamPropertyVirtualFormat, defaultValue: AudioStreamBasicDescription())
            guard AudioBufferRenderer.supports(format) else {
                throw NSError(domain: "ProcessTapController", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unsupported output format"])
            }
        }
    }

    // MARK: - Private Implementation

    private static func findProcessObjectID(for pid: pid_t) -> AudioObjectID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize) == noErr else { return nil }

        let count = Int(propertySize) / MemoryLayout<AudioObjectID>.size
        var objectList = [AudioObjectID](repeating: 0, count: count)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &objectList) == noErr else { return nil }

        for objectID in objectList {
            var processPID: pid_t = 0
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pidSize = UInt32(MemoryLayout<pid_t>.size)

            if AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &pidSize, &processPID) == noErr {
                if processPID == pid {
                    return objectID
                }
            }
        }
        return nil
    }

    private func getDefaultOutputDeviceUID() -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioObjectID()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        outputDeviceID = deviceID

        propertyAddress.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<CFString>.size)

        let uidStatus = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size,
            &uid
        )

        guard uidStatus == noErr, let cfUID = uid else { return nil }
        return cfUID.takeRetainedValue() as String
    }

    private func buildAggregateDescription(outputUID: String, tapUUID: UUID, name: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: false
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]
    }

    private func cleanupPartialActivation() {
        _ = invalidate()
    }

    /// The undocumented HAL 'duck' property is capability-checked on each device.
    /// Never amplify samples if it is absent or rejected. Run off the audio callback.
    /// This clears transient ducking only; it does not change hardware/user volume.
    func restoreDeviceDucking() {
        guard activated else { return }
        var results: [String] = []
        for device in [outputDeviceID, aggregateDeviceID] where device != .unknown {
            for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeGlobal] {
                var address = AudioObjectPropertyAddress(
                    mSelector: 0x6475636B, // 'duck', not a documented SDK constant
                    mScope: scope, mElement: kAudioObjectPropertyElementMain
                )
                guard AudioObjectHasProperty(device, &address) else { continue }
                var settable: DarwinBoolean = false
                var size: UInt32 = 0
                guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                      settable.boolValue,
                      AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
                      size == 4 * MemoryLayout<Float32>.size else { continue }
                var current = [Float32](repeating: 0, count: 4)
                let readStatus = current.withUnsafeMutableBytes {
                    AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!)
                }
                guard readStatus == noErr, current.allSatisfy({ $0.isFinite }) else { continue }
                // Avoid writing an unchanged property every half second.
                let unity: [Float32] = [1, 0, 0, 0]
                let status: OSStatus = current == unity ? noErr : unity.withUnsafeBytes {
                    AudioObjectSetPropertyData(device, &address, 0, nil, size, $0.baseAddress!)
                }
                results.append("\(device)/\(scope):\(status)")
            }
        }
        let result = results.isEmpty ? "unsupported; unity-gain routing only" : results.joined(separator: ",")
        if result != lastDuckingResult {
            logger.info("Device ducking restore: \(result)")
            lastDuckingResult = result
        }
    }

    // MARK: - RT-Safe Audio Callback

    private func processAudio(_ inputBufferList: UnsafePointer<AudioBufferList>, to outputBufferList: UnsafeMutablePointer<AudioBufferList>) {
        callbackCount &+= 1
        if AudioBufferRenderer.render(input: inputBufferList, output: outputBufferList,
                                      tapChannels: tapChannels, targetVolume: _volume,
                                      currentVolume: &_currentVolume, rampCoefficient: rampCoefficient, muted: _isMuted) {
            validBufferCount &+= 1
        }
    }

    static func renderSample(_ sample: Float, gain: Float) -> Float {
        AudioBufferRenderer.renderSample(sample, gain: gain)
    }
}
