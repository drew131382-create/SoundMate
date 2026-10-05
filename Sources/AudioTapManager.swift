import AppKit
import CoreAudio
import Darwin
import Foundation
import os

protocol AudioTapManagerProtocol {
    var onRecoveryStateChange: (([pid_t: String]) -> Void)? { get set }
    func updateRoutes(_ targets: [AudioRouteTarget], callEnded: Bool)
    func setState(for pid: pid_t, volume: Float, muted: Bool)
    func resetAudio()
    func resetAudio(for pid: pid_t)
    func shutdown(completion: @escaping () -> Void)
}

class AudioTapManagerFactory {
    static func create() -> AudioTapManagerProtocol {
        if #available(macOS 14.2, *) { return AudioTapManager() }
        return AudioTapManagerFallback()
    }
}

@available(macOS 14.2, *)
final class AudioTapManager: AudioTapManagerProtocol {
    var onRecoveryStateChange: (([pid_t: String]) -> Void)?
    private let queue = DispatchQueue(label: "com.soundmate.audiotap", qos: .userInitiated)
    private let logger = Logger(subsystem: "SoundMate", category: "AudioRoutes")
    private var healthTimer: DispatchSourceTimer?
    private var unduckTimer: DispatchSourceTimer?
    private var lastDefaultDuckingResult: String?
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    private var wakeObserver: NSObjectProtocol?
    private var stopped = false
    private var deviceChangePropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private lazy var routes = AudioRouteCoordinator(
        queue: queue,
        makeTap: {
            guard let tap = ProcessTapController(pid: $0.pid, processObjectID: $0.processObjectID),
                  tap.isSourceOutputting == true else { return nil }
            return tap
        },
        log: { [logger] message in logger.notice("\(message, privacy: .public)") }
    )

    init() {
        routes.onFailureChange = { [weak self] failures in
            guard let self else { return }
            self.refreshTimers()
            DispatchQueue.main.async { [weak self] in self?.onRecoveryStateChange?(failures) }
        }
        deviceChangeListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async { [weak self] in self?.handleDeviceChange() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceChangePropertyAddress,
            queue, deviceChangeListenerBlock!
        )
        if status != noErr { logger.error("Default device listener failed status=\(status)") }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in self?.handleDeviceChange() }
        }
    }

    deinit {
        healthTimer?.cancel()
        unduckTimer?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let block = deviceChangeListenerBlock {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                &deviceChangePropertyAddress, queue, block)
        }
        // Normal termination explicitly drains this queue before deinitializing.
        _ = routes.shutdown()
    }

    func updateRoutes(_ targets: [AudioRouteTarget], callEnded: Bool) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.routes.reconcile(targets, callEnded: callEnded)
            self.refreshTimers()
        }
    }

    func setState(for pid: pid_t, volume: Float, muted: Bool) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.routes.setState(pid: pid, volume: volume, muted: muted)
            self.refreshTimers()
        }
    }

    func resetAudio() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.routes.reset()
            self.refreshTimers()
        }
    }

    func resetAudio(for pid: pid_t) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.routes.reset(pid: pid)
            self.refreshTimers()
        }
    }

    func shutdown(completion: @escaping () -> Void) {
        queue.async { [self] in
            stopped = true
            healthTimer?.cancel()
            healthTimer = nil
            stopUnduckTimer()
            let released = routes.shutdown()
            logger.notice("Audio shutdown released=\(released)")
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func handleDeviceChange() {
        guard !stopped else { return }
        logger.notice("Default output changed or system woke; refreshing routes")
        routes.topologyChanged()
        refreshTimers()
    }

    private func refreshTimers() {
        if !stopped && routes.hasRoutes {
            if healthTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
                timer.setEventHandler { [weak self] in self?.routes.checkHealth() }
                healthTimer = timer
                timer.resume()
            }
        } else {
            healthTimer?.cancel()
            healthTimer = nil
        }
        if !stopped && !routes.protectedTaps.isEmpty { startUnduckTimer() }
        else { stopUnduckTimer() }
    }

    private func startUnduckTimer() {
        guard unduckTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, !self.routes.protectedTaps.isEmpty else { return }
            self.restoreDefaultDeviceDucking()
            for tap in self.routes.protectedTaps { tap.restoreDeviceDucking() }
        }
        unduckTimer = timer
        timer.resume()
    }

    private func stopUnduckTimer() {
        unduckTimer?.cancel()
        unduckTimer = nil
        lastDefaultDuckingResult = nil
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

}

final class AudioTapManagerFallback: AudioTapManagerProtocol {
    var onRecoveryStateChange: (([pid_t: String]) -> Void)?
    func updateRoutes(_ targets: [AudioRouteTarget], callEnded: Bool) {}
    func setState(for pid: pid_t, volume: Float, muted: Bool) {}
    func resetAudio() {}
    func resetAudio(for pid: pid_t) {}
    func shutdown(completion: @escaping () -> Void) { completion() }
}
