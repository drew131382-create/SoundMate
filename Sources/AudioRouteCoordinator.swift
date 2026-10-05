import CoreAudio
import Foundation

struct AudioRouteTarget: Equatable {
    let pid: pid_t
    let processObjectID: AudioObjectID
    var volume: Float
    var muted: Bool
    var callProtected: Bool

    var needsRoute: Bool { callProtected || volume != 1 || muted }
    var wantsSound: Bool { !muted && volume > 0 }
}

struct AudioRouteHealth {
    let callbacks: UInt64
    let validBuffers: UInt64
}

/// All lifecycle operations run on the coordinator's control queue. Health
/// counters belong to the I/O queue and are returned asynchronously.
protocol AudioRouteTap: AnyObject {
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var isSourceOutputting: Bool? { get }
    func activate() throws
    @discardableResult func invalidate() -> Bool
    func readHealth(_ completion: @escaping (AudioRouteHealth) -> Void)
    func watchTopology(on queue: DispatchQueue, changed: @escaping () -> Void)
    func restoreDeviceDucking()
}

/// Latest desired state is authoritative: scheduled retries never own a PID.
/// Injected clock, scheduler and Tap factory allow real failure-order testing.
final class AudioRouteCoordinator {
    private final class Entry {
        var target: AudioRouteTarget
        var generation: UInt64
        var tap: AudioRouteTap?
        var attempts = 0
        var retryPending = false
        var failure: String?
        var topologyDirty = false
        var lastProgress: TimeInterval = 0
        var healthySince: TimeInterval = 0
        var healthRequestedAt: TimeInterval?
        var lastHealth = AudioRouteHealth(callbacks: 0, validBuffers: 0)
        var confirmedIO = false

        init(target: AudioRouteTarget, generation: UInt64) {
            self.target = target
            self.generation = generation
        }
    }

    private var entries: [pid_t: Entry] = [:]
    private var generation: UInt64 = 0
    private var stopped = false
    private let queue: DispatchQueue
    private let makeTap: (AudioRouteTarget) -> AudioRouteTap?
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let log: (String) -> Void
    var onFailureChange: (([pid_t: String]) -> Void)?

    init(
        queue: DispatchQueue,
        makeTap: @escaping (AudioRouteTarget) -> AudioRouteTap?,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
        log: @escaping (String) -> Void = { NSLog("SoundMate: %@", $0) }
    ) {
        self.queue = queue
        self.makeTap = makeTap
        self.now = now
        self.schedule = schedule ?? { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) }
        self.log = log
    }

    var hasRoutes: Bool { entries.values.contains { $0.tap != nil || ($0.target.needsRoute && $0.failure == nil) } }
    var protectedTaps: [AudioRouteTap] { entries.values.filter { $0.target.callProtected }.compactMap(\.tap) }

    func reconcile(_ targets: [AudioRouteTarget], callEnded: Bool) {
        guard !stopped else { return }
        let desired = Dictionary(targets.map { ($0.pid, $0) }, uniquingKeysWith: { _, latest in latest })
        for pid in Set(entries.keys).subtracting(desired.keys) {
            guard retire(pid) else { continue }
            entries.removeValue(forKey: pid)
        }
        for target in desired.values {
            if let entry = entries[target.pid] {
                let identityChanged = entry.target.processObjectID != target.processObjectID
                let refreshAfterCall = callEnded && entry.target.callProtected && target.wantsSound
                let becomingAudible = !entry.target.wantsSound && target.wantsSound
                let staleTopology = entry.topologyDirty && target.wantsSound
                let settingsChanged = entry.target.volume != target.volume || entry.target.muted != target.muted
                entry.target = target
                if identityChanged || refreshAfterCall || becomingAudible || staleTopology || (settingsChanged && entry.failure != nil) {
                    recover(target.pid, reason: identityChanged ? "process object changed" : "call ended or settings changed")
                } else {
                    apply(target.pid)
                }
            } else {
                entries[target.pid] = Entry(target: target, generation: nextGeneration())
                apply(target.pid)
            }
        }
        publishFailures()
    }

    func setState(pid: pid_t, volume: Float, muted: Bool) {
        guard !stopped, let entry = entries[pid] else { return }
        let becomingAudible = !entry.target.wantsSound && !muted && volume > 0
        let changed = entry.target.volume != volume || entry.target.muted != muted
        entry.target.volume = volume
        entry.target.muted = muted
        if becomingAudible || (changed && entry.failure != nil) {
            recover(pid, reason: "user changed state")
        } else {
            apply(pid)
        }
        publishFailures()
    }

    func reset() {
        guard !stopped else { return }
        for pid in Array(entries.keys) { recover(pid, reason: "manual reset") }
        publishFailures()
    }

    func reset(pid: pid_t) {
        guard !stopped else { return }
        recover(pid, reason: "manual app reset")
        publishFailures()
    }

    func topologyChanged() {
        guard !stopped else { return }
        for (pid, entry) in entries {
            if entry.target.wantsSound {
                recover(pid, reason: "default device changed or wake")
            } else {
                entry.topologyDirty = true
            }
        }
        publishFailures()
    }

    /// Does not infer failure from sample amplitude. Silent frames are valid.
    func checkHealth() {
        guard !stopped else { return }
        for (pid, entry) in entries {
            guard let tap = entry.tap, entry.failure == nil, entry.target.wantsSound else { continue }
            guard let outputting = tap.isSourceOutputting else {
                if now() - entry.lastProgress >= 3 { recover(pid, reason: "process object unavailable", resetAttempts: false) }
                continue
            }
            guard outputting else {
                entry.lastProgress = now()
                continue
            }
            if let requestedAt = entry.healthRequestedAt {
                if now() - requestedAt >= 3 { recover(pid, reason: "I/O queue stopped responding", resetAttempts: false) }
                continue
            }
            entry.healthRequestedAt = now()
            let token = entry.generation
            tap.readHealth { [weak self] snapshot in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, !self.stopped, let current = self.entries[pid], current.generation == token else { return }
                    current.healthRequestedAt = nil
                    if snapshot.callbacks > current.lastHealth.callbacks && snapshot.validBuffers > current.lastHealth.validBuffers {
                        if !current.confirmedIO {
                            self.log("route I/O confirmed pid=\(pid), object=\(current.target.processObjectID), generation=\(token)")
                            current.confirmedIO = true
                        }
                        current.lastProgress = self.now()
                        if self.now() - current.healthySince >= 10 { current.attempts = 0 }
                    } else if self.now() - current.lastProgress >= 3, current.tap?.isSourceOutputting == true {
                        self.recover(pid, reason: "no valid I/O progress", resetAttempts: false)
                        self.publishFailures()
                        return
                    }
                    current.lastHealth = snapshot
                }
            }
        }
        publishFailures()
    }

    @discardableResult
    func shutdown() -> Bool {
        stopped = true
        var success = true
        for pid in Array(entries.keys) {
            if !retire(pid) { success = false }
        }
        if success { entries.removeAll() }
        publishFailures()
        return success
    }

    private func nextGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Completion is synchronous on the control queue, never the main/I/O queue.
    /// A failed release blocks replacement so two taps cannot own one source.
    @discardableResult
    private func retire(_ pid: pid_t) -> Bool {
        guard let entry = entries[pid] else { return true }
        entry.generation = nextGeneration()
        entry.retryPending = false
        entry.healthRequestedAt = nil
        guard entry.tap?.invalidate() != false else {
            entry.failure = "音频路由释放失败，请重置音频"
            log("route release failed pid=\(pid), object=\(entry.target.processObjectID), generation=\(entry.generation)")
            return false
        }
        entry.tap = nil
        return true
    }

    private func recover(_ pid: pid_t, reason: String, resetAttempts: Bool = true) {
        guard let entry = entries[pid], retire(pid) else { return }
        log("route recovery pid=\(pid), object=\(entry.target.processObjectID), generation=\(entry.generation), reason=\(reason)")
        if resetAttempts { entry.attempts = 0 }
        entry.failure = nil
        entry.topologyDirty = false
        entry.lastHealth = AudioRouteHealth(callbacks: 0, validBuffers: 0)
        entry.confirmedIO = false
        apply(pid)
    }

    private func apply(_ pid: pid_t) {
        guard let entry = entries[pid] else { return }
        guard entry.target.needsRoute else {
            if retire(pid) { entry.failure = nil; entry.attempts = 0 }
            return
        }
        guard entry.failure == nil else { return }
        if let tap = entry.tap {
            tap.volume = entry.target.volume
            tap.isMuted = entry.target.muted
            return
        }
        guard !entry.retryPending else { return }
        guard entry.attempts < 3 else {
            entry.failure = entry.target.muted || entry.target.volume == 0
                ? "静音控制异常，请重置音频并检查播放状态"
                : "音量控制暂不可用，已释放路由接管"
            log("route retries exhausted pid=\(pid), object=\(entry.target.processObjectID)")
            publishFailures()
            return
        }
        entry.attempts += 1
        if let tap = makeTap(entry.target) {
            // Seed user state before AudioDeviceStart can invoke the callback.
            tap.volume = entry.target.volume
            tap.isMuted = entry.target.muted
            do {
                try tap.activate()
                entry.tap = tap
                entry.lastProgress = now()
                entry.healthySince = now()
                let token = entry.generation
                tap.watchTopology(on: queue) { [weak self] in
                    guard let self, !self.stopped, let latest = self.entries[pid], latest.generation == token else { return }
                    // Preserve an explicit mute through topology changes. Its
                    // route is refreshed when the user requests sound again.
                    guard latest.target.wantsSound else { latest.topologyDirty = true; return }
                    self.recover(pid, reason: "device or stream changed", resetAttempts: false)
                    self.publishFailures()
                }
                log("route active pid=\(pid), object=\(entry.target.processObjectID), generation=\(token), attempt=\(entry.attempts)")
                return
            } catch {
                log("route activation failed pid=\(pid), attempt=\(entry.attempts), error=\(error)")
                // Keep partial resources reachable if HAL rejected their release.
                if !tap.invalidate() {
                    entry.tap = tap
                    entry.failure = "音频路由释放失败，请重置音频"
                    publishFailures()
                    return
                }
            }
        }
        entry.retryPending = true
        let token = entry.generation
        schedule(0.25 * Double(entry.attempts)) { [weak self] in
            guard let self, !self.stopped, let latest = self.entries[pid], latest.generation == token else { return }
            latest.retryPending = false
            self.apply(pid)
            self.publishFailures()
        }
    }

    private func publishFailures() {
        onFailureChange?(entries.reduce(into: [:]) { result, item in
            if let failure = item.value.failure { result[item.key] = failure }
        })
    }
}
