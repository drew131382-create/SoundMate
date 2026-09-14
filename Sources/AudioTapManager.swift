import CoreAudio
import Darwin
import Foundation

/// Protocol for audio tap management
protocol AudioTapManagerProtocol {
    func setVolume(for pid: pid_t, volume: Float)
    func setMute(for pid: pid_t, muted: Bool)
    func setCallRouting(for pid: pid_t, enabled: Bool)
    func endCallRouting()
    func removeTap(for pid: pid_t)
    func removeUnusedTaps(keeping activePIDs: Set<pid_t>)
    func resetAudio()
}

/// Factory to create the appropriate tap manager based on OS version
class AudioTapManagerFactory {
    static func create() -> AudioTapManagerProtocol {
        if #available(macOS 14.2, *) {
            return AudioTapManager()
        } else {
            return AudioTapManagerFallback()
        }
    }
}

/// Audio tap manager using ProcessTapController for proper volume/mute control
@available(macOS 14.2, *)
class AudioTapManager: AudioTapManagerProtocol {

    private var activeTaps: [pid_t: ProcessTapController] = [:]
    private var tapStates: [pid_t: (volume: Float, muted: Bool)] = [:]
    /// Keep unity-gain routes alive during calls without amplifying media.
    private var callRoutingPIDs: Set<pid_t> = []
    private var unduckTimer: DispatchSourceTimer?
    private var lastDefaultDuckingResult: String?
    private let queue = DispatchQueue(label: "com.soundmate.audiotap", qos: .userInteractive)

    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceChangePropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        NSLog("SoundMate: AudioTapManager initialized")
        startDeviceChangeListener()
    }

    deinit {
        unduckTimer?.cancel()
        if let block = deviceChangeListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &deviceChangePropertyAddress,
                queue,
                block
            )
        }
        for (_, tap) in activeTaps {
            tap.invalidate()
        }
    }

    private func startDeviceChangeListener() {
        deviceChangeListenerBlock = { [weak self] _, _ in
            self?.handleDeviceChange()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceChangePropertyAddress,
            queue,
            deviceChangeListenerBlock!
        )

        if status != noErr {
            NSLog("SoundMate: Failed to register device change listener: \(status)")
        }
    }

    private func handleDeviceChange() {
        NSLog("SoundMate: Output device changed - recreating taps")

        for (pid, tap) in activeTaps {
            tapStates[pid] = (volume: tap.volume, muted: tap.isMuted)
        }

        let pidsToRecreate = Array(activeTaps.keys)
        for (pid, tap) in activeTaps {
            tap.invalidate()
            NSLog("SoundMate: Invalidated tap for PID: \(pid)")
        }
        activeTaps.removeAll()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

            self.queue.async {
                for pid in pidsToRecreate {
                    self.recreateTapWithRetry(pid: pid, attempt: 1, maxAttempts: 3)
                }
            }
        }
    }

    private func recreateTapWithRetry(pid: pid_t, attempt: Int, maxAttempts: Int) {
        guard let tap = ProcessTapController(pid: pid) else {
            if attempt < maxAttempts {
                let delay = Double(attempt) * 0.1
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.queue.async {
                        self?.recreateTapWithRetry(pid: pid, attempt: attempt + 1, maxAttempts: maxAttempts)
                    }
                }
            } else {
                NSLog("SoundMate: Could not recreate tap for PID \(pid)")
            }
            return
        }

        do {
            if let state = self.tapStates[pid] {
                tap.volume = state.volume
                tap.isMuted = state.muted
            }
            try tap.activate()

            self.activeTaps[pid] = tap
        } catch {
            if attempt < maxAttempts {
                let delay = Double(attempt) * 0.1
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.queue.async {
                        self?.recreateTapWithRetry(pid: pid, attempt: attempt + 1, maxAttempts: maxAttempts)
                    }
                }
            } else {
                NSLog("SoundMate: Failed to reactivate tap for PID \(pid): \(error.localizedDescription)")
            }
        }
    }

    func setVolume(for pid: pid_t, volume: Float) {
        queue.async { [weak self] in
            guard let self = self else { return }

            if let existingTap = self.activeTaps[pid] {
                existingTap.volume = volume
                self.tapStates[pid] = (volume: volume, muted: existingTap.isMuted)
                self.removeTapIfIdle(for: pid)
            } else {
                if volume != 1.0 {
                    self.tapStates[pid] = (volume: volume, muted: false)
                    self.ensureTapExists(for: pid)
                    self.activeTaps[pid]?.volume = volume
                    self.tapStates[pid] = (volume: volume, muted: false)
                }
            }
        }
    }

    func setCallRouting(for pid: pid_t, enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }

            if enabled {
                self.callRoutingPIDs.insert(pid)
                self.startUnduckTimer()
                self.ensureTapExists(for: pid)
            } else {
                self.callRoutingPIDs.remove(pid)
                self.removeTapIfIdle(for: pid)
                if self.callRoutingPIDs.isEmpty {
                    self.stopUnduckTimer()
                }
            }
        }
    }

    /// Release every call-only route when the communication session ends.
    /// User-controlled non-unity volume or mute taps remain available.
    func endCallRouting() {
        queue.async { [weak self] in
            guard let self else { return }

            let callPIDs = self.callRoutingPIDs
            self.callRoutingPIDs.removeAll()
            self.stopUnduckTimer()
            for pid in callPIDs {
                self.removeTapIfIdle(for: pid)
            }
            if !callPIDs.isEmpty {
                NSLog("SoundMate: 通话结束，释放通话专用音频路由 \(callPIDs.count) 个")
            }
        }
    }

    /// Restore the output device while a call route is active. The timer is lazy
    /// so simply opening SoundMate never changes the system audio path.
    private func startUnduckTimer() {
        guard unduckTimer == nil else { return }
        NSLog("SoundMate: Starting device ducking restore timer")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.lastDefaultDuckingResult == nil {
                NSLog("SoundMate: Device ducking restore timer fired")
            }
            self.restoreDefaultDeviceDucking()
            // Private aggregate devices can also expose the same property. Keep
            // their routes at unity while they are owned by this manager.
            for tap in self.activeTaps.values {
                tap.restoreDeviceDucking()
            }
        }
        unduckTimer = timer
        timer.resume()
    }

    private func stopUnduckTimer() {
        guard unduckTimer != nil else { return }
        unduckTimer?.cancel()
        unduckTimer = nil
        lastDefaultDuckingResult = nil
        NSLog("SoundMate: Stopped device ducking restore timer")
    }

    private func restoreDefaultDeviceDucking() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = .unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != .unknown else { return }

        let selector: AudioObjectPropertySelector = 0x6475636B // 'duck'
        address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            recordDefaultDuckingResult("hal=unsupported")
            return
        }

        var settable = DarwinBoolean(false)
        var propertySize: UInt32 = 0
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
              settable.boolValue,
              AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize) == noErr,
              propertySize == 4 * MemoryLayout<Float32>.size else {
            recordDefaultDuckingResult("hal=read-only-or-unexpected-size")
            return
        }

        var unity: [Float32] = [1, 0, 0, 0]
        let status = unity.withUnsafeMutableBytes {
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, propertySize, $0.baseAddress!)
        }
        recordDefaultDuckingResult("device=\(deviceID),hal=\(status)")
    }

    private func recordDefaultDuckingResult(_ result: String) {
        guard result != lastDefaultDuckingResult else { return }
        lastDefaultDuckingResult = result
        NSLog("SoundMate: Default device ducking restore: \(result)")
    }

    func setMute(for pid: pid_t, muted: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }

            if let existingTap = self.activeTaps[pid] {
                existingTap.isMuted = muted
                self.tapStates[pid] = (volume: existingTap.volume, muted: muted)
                self.removeTapIfIdle(for: pid)
            } else {
                if muted {
                    self.tapStates[pid] = (volume: 1.0, muted: true)
                    self.ensureTapExists(for: pid)
                    if let tap = self.activeTaps[pid] {
                        tap.isMuted = muted
                    }
                } else {
                    self.tapStates.removeValue(forKey: pid)
                }
            }
        }
    }

    func removeTap(for pid: pid_t) {
        queue.async { [weak self] in
            self?.callRoutingPIDs.remove(pid)
            if let tap = self?.activeTaps.removeValue(forKey: pid) {
                tap.invalidate()
            }
            self?.tapStates.removeValue(forKey: pid)
        }
    }

    func removeUnusedTaps(keeping activePIDs: Set<pid_t>) {
        queue.async { [weak self] in
            guard let self else { return }

            self.callRoutingPIDs.formIntersection(activePIDs)
            if self.callRoutingPIDs.isEmpty {
                self.stopUnduckTimer()
            }
            let staleStatePIDs = Set(self.tapStates.keys).subtracting(activePIDs)
            for pid in staleStatePIDs {
                self.tapStates.removeValue(forKey: pid)
            }

            let stalePIDs = Set(self.activeTaps.keys).subtracting(activePIDs)
            for pid in stalePIDs {
                if let tap = self.activeTaps.removeValue(forKey: pid) {
                    tap.invalidate()
                    self.tapStates.removeValue(forKey: pid)
                }
            }
        }
    }

    func resetAudio() {
        queue.async { [weak self] in
            guard let self else { return }

            for (pid, tap) in self.activeTaps {
                self.tapStates[pid] = (volume: tap.volume, muted: tap.isMuted)
                tap.invalidate()
            }

            let pidsToRecreate = self.tapStates.keys.filter { self.isProcessRunning($0) }
            self.activeTaps.removeAll()

            for pid in pidsToRecreate {
                self.recreateTapWithRetry(pid: pid, attempt: 1, maxAttempts: 3)
            }
        }
    }

    private func removeTapIfIdle(for pid: pid_t) {
        guard !callRoutingPIDs.contains(pid) else { return }
        guard let tap = activeTaps[pid], tap.volume == 1.0, !tap.isMuted else { return }
        activeTaps.removeValue(forKey: pid)
        tapStates.removeValue(forKey: pid)
        tap.invalidate()
    }

    // MARK: - Private Implementation

    private func ensureTapExists(for pid: pid_t) {
        guard activeTaps[pid] == nil else { return }

        guard let tap = ProcessTapController(pid: pid) else {
            NSLog("SoundMate: Could not create ProcessTapController for PID \(pid)")
            return
        }

        do {
            if let state = tapStates[pid] {
                tap.volume = state.volume
                tap.isMuted = state.muted
            }
            try tap.activate()
            activeTaps[pid] = tap
        } catch {
            NSLog("SoundMate: Failed to activate tap for PID \(pid): \(error.localizedDescription)")
        }
    }

    private func isProcessRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

// MARK: - Fallback for older macOS

class AudioTapManagerFallback: AudioTapManagerProtocol {
    func setVolume(for pid: pid_t, volume: Float) {
        NSLog("SoundMate: Volume control not available on this macOS version")
    }
    func setMute(for pid: pid_t, muted: Bool) {
        NSLog("SoundMate: Mute control not available on this macOS version")
    }
    func setCallRouting(for pid: pid_t, enabled: Bool) {}
    func endCallRouting() {}
    func removeTap(for pid: pid_t) {}
    func removeUnusedTaps(keeping activePIDs: Set<pid_t>) {}
    func resetAudio() {}

    init() {
        NSLog("SoundMate: AudioTap requires macOS 14.2+")
    }
}
