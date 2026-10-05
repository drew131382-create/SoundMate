import CoreAudio
import Foundation

private final class FakeTap: AudioRouteTap {
    var volume: Float = 1
    var isMuted = false
    var isSourceOutputting: Bool? = true
    var health = AudioRouteHealth(callbacks: 0, validBuffers: 0)
    var topology: (() -> Void)?
    var failActivation = false
    var failRelease = false
    var active = false
    var activationState: (Float, Bool)?
    var holdHealth = false
    var pendingHealth: ((AudioRouteHealth) -> Void)?
    let id: Int
    let record: (String) -> Void

    init(id: Int, record: @escaping (String) -> Void) { self.id = id; self.record = record }
    func activate() throws {
        activationState = (volume, isMuted)
        if failActivation { throw NSError(domain: "Injected", code: 1) }
        active = true
        record("start \(id)")
    }
    func invalidate() -> Bool {
        if failRelease { record("release failed \(id)"); return false }
        if active { record("stop \(id)") }
        active = false
        return true
    }
    func readHealth(_ completion: @escaping (AudioRouteHealth) -> Void) {
        if holdHealth { pendingHealth = completion }
        else { completion(health) }
    }
    func watchTopology(on queue: DispatchQueue, changed: @escaping () -> Void) { topology = changed }
    func restoreDeviceDucking() {}
}

private final class Harness {
    let queue = DispatchQueue(label: "RouteTests")
    var time: TimeInterval = 0
    var scheduled: [() -> Void] = []
    var taps: [FakeTap] = []
    var events: [String] = []
    var failures: [pid_t: String] = [:]
    var failCreations = false
    var failedFactories = 0
    lazy var routes: AudioRouteCoordinator = {
        let coordinator = AudioRouteCoordinator(queue: queue, makeTap: { [unowned self] _ in
            if self.failCreations { self.failedFactories += 1; return nil }
            let tap = FakeTap(id: self.taps.count) { [unowned self] in self.events.append($0) }
            self.taps.append(tap)
            return tap
        }, now: { [unowned self] in self.time }, schedule: { [unowned self] _, task in
            self.scheduled.append(task)
        }, log: { _ in })
        coordinator.onFailureChange = { [unowned self] in self.failures = $0 }
        return coordinator
    }()

    func target(object: AudioObjectID = 101, volume: Float = 0.15, muted: Bool = false, call: Bool = false) -> AudioRouteTarget {
        AudioRouteTarget(pid: 42, processObjectID: object, volume: volume, muted: muted, callProtected: call)
    }
    func reconcile(_ targets: [AudioRouteTarget], ended: Bool = false) {
        queue.sync { routes.reconcile(targets, callEnded: ended) }
    }
    func runScheduled() {
        let tasks = scheduled
        scheduled.removeAll()
        queue.sync { tasks.forEach { $0() } }
    }
    func health(after seconds: Double) {
        queue.sync { time += seconds; routes.checkHealth() }
        queue.sync {} // Consume health replies on the same control queue.
    }
}

@main
enum AudioRouteRecoveryTests {
    static func main() {
        do {
            let h = Harness()
            h.reconcile([h.target(call: true)])
            h.reconcile([h.target()], ended: true)
            precondition(h.taps.count == 2)
            precondition(h.events == ["start 0", "stop 0", "start 1"])
            precondition(h.taps[1].activationState!.0 == 0.15)
            h.reconcile([h.target(volume: 1)])
            precondition(!h.taps[1].active)
        }
        do {
            let h = Harness()
            h.reconcile([h.target(muted: true, call: true)])
            h.reconcile([h.target(muted: true)], ended: true)
            h.queue.sync { h.routes.topologyChanged() }
            h.health(after: 20)
            precondition(h.taps.count == 1 && h.taps[0].active, "Mute was released by automatic recovery")
            precondition(h.taps[0].activationState!.1)
            h.queue.sync { h.routes.setState(pid: 42, volume: 0.15, muted: false) }
            precondition(h.taps.count == 2 && !h.taps[1].activationState!.1)
            precondition(h.taps[1].activationState!.0 == 0.15)
        }
        do {
            let h = Harness()
            h.failCreations = true
            h.reconcile([h.target()])
            h.reconcile([])
            h.failCreations = false
            h.runScheduled()
            precondition(h.taps.isEmpty, "Removed PID was resurrected by retry")
        }
        do {
            let h = Harness()
            h.failCreations = true
            h.reconcile([h.target(volume: 1, call: true)])
            h.reconcile([h.target(volume: 1)], ended: true)
            h.failCreations = false
            h.runScheduled()
            precondition(h.taps.isEmpty, "Call-only retry survived call end")
        }
        do {
            let h = Harness()
            h.reconcile([h.target()])
            let oldNotification = h.taps[0].topology!
            h.reconcile([h.target(object: 202)])
            h.queue.sync { oldNotification() }
            precondition(h.taps.count == 2, "Stale object notification rebuilt replacement")
            precondition(h.events == ["start 0", "stop 0", "start 1"])
        }
        do {
            let h = Harness()
            h.reconcile([h.target()])
            h.taps[0].failRelease = true
            h.queue.sync { h.routes.reset() }
            precondition(h.taps.count == 1 && !h.failures.isEmpty, "Created a replacement before release succeeded")
            h.taps[0].failRelease = false
            h.queue.sync { h.routes.reset() }
            precondition(h.taps.count == 2 && h.failures.isEmpty)
        }
        do {
            let h = Harness()
            h.failCreations = true
            h.reconcile([h.target()])
            h.runScheduled(); h.runScheduled(); h.runScheduled()
            precondition(h.failedFactories == 3 && !h.failures.isEmpty)
            h.reconcile([h.target()])
            precondition(h.failedFactories == 3, "Polling retried forever after bypass")
            h.failCreations = false
            h.queue.sync { h.routes.reset(pid: 42) }
            precondition(h.taps.count == 1 && h.failures.isEmpty)
        }
        do {
            let h = Harness()
            h.reconcile([h.target()])
            h.health(after: 4)
            h.health(after: 4)
            h.health(after: 4)
            precondition(h.taps.count == 3 && h.taps.allSatisfy { !$0.active })
            precondition(!h.failures.isEmpty, "Repeated I/O stalls failed to release control")
        }
        do {
            let h = Harness()
            h.reconcile([h.target()])
            h.taps[0].isSourceOutputting = false
            h.health(after: 20)
            precondition(h.taps.count == 1, "Paused source was treated as a failure")
            h.taps[0].isSourceOutputting = true
            h.taps[0].health = AudioRouteHealth(callbacks: 100, validBuffers: 100)
            h.health(after: 4)
            precondition(h.taps.count == 1, "Valid silent frames were treated as a failure")
        }
        do {
            let h = Harness()
            h.reconcile([h.target()])
            h.taps[0].holdHealth = true
            h.health(after: 1)
            let oldReply = h.taps[0].pendingHealth!
            h.reconcile([h.target(object: 202)])
            oldReply(AudioRouteHealth(callbacks: 999, validBuffers: 999))
            h.queue.sync {}
            precondition(h.taps.count == 2)
            h.health(after: 4)
            precondition(h.taps.count == 3, "Old health reply masked a new route failure")
        }
        do {
            let h = Harness()
            h.failCreations = true
            h.reconcile([h.target()])
            h.queue.sync { precondition(h.routes.shutdown()) }
            h.failCreations = false
            h.runScheduled()
            h.reconcile([h.target()])
            precondition(h.taps.isEmpty, "Shutdown allowed a late route activation")
        }
        do {
            let h = Harness()
            h.reconcile([h.target(volume: 0)])
            precondition(h.taps[0].activationState!.0 == 0)
            h.reconcile([])
            precondition(!h.taps[0].active)
        }
        print("PASS: 12 route recovery scenarios, stale tasks, cleanup ordering, bounded failure and user state")
    }
}
