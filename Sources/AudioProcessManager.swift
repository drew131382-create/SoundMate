import AppKit
import Combine
import CoreAudio
import Darwin
import Foundation

/// Manages detection and tracking of applications that are outputting audio
@MainActor
class AudioProcessManager: ObservableObject {
    @Published var audioApps: [AudioApp] = []
    @Published var masterVolume: Float = 1.0
    @Published var masterMuted: Bool = false
    @Published private(set) var canSetMasterVolume = false
    @Published private(set) var canSetMasterMute = false
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var selectedInputDeviceID: AudioObjectID = .unknown
    @Published private(set) var selectedOutputDeviceID: AudioObjectID = .unknown
    @Published private(set) var isCommunicationCallProtectionActive = false
    @Published private(set) var activeCommunicationAppNames: [String] = []
    @Published private(set) var communicationExcludedBundleIDs: Set<String> = []

    private let deviceVolume = DeviceVolume()
    private var tapManager: AudioTapManagerProtocol?
    private var updateTimer: Timer?
    private let idleMonitoringInterval: TimeInterval = 15.0
    private let outputMonitoringInterval: TimeInterval = 4.0
    private let communicationMonitoringInterval: TimeInterval = 2.0
    private var cancellables = Set<AnyCancellable>()
    private let volumeState = VolumeState()
    private var isUpdatingAudioApps = false
    /// 当前存在 Core Audio 进程对象的 PID 集合。
    /// 这比瞬时的“正在输出”集合稳定，适合绑定各通话软件的动态 Helper。
    private var audioPIDs: Set<pid_t> = []
    private var outputAudioPIDs: Set<pid_t> = []
    /// 在通话期间保持其他应用不被通话模式压低的进程集合。
    private var communicationProtectedPIDs: Set<pid_t> = []
    /// 避免 Core Audio 短暂丢失输入/输出状态时反复开关补偿。
    private var communicationCallHoldUntil = Date.distantPast
    private var communicationCandidateSignature: String?
    private var communicationCandidateCount = 0
    private var communicationCallAppKeys: Set<String> = []
    private let communicationExcludedDefaultsKey = "SoundMate.ExcludedApps"
    private var lastLoggedAudioSignature: String?
    /// 当前运行期间按稳定应用标识保存的目标增益/静音状态。
    /// 不按 PID 保存，避免 Helper 切换后回到 100%。
    private var desiredVolumesByIdentifier: [String: Float] = [:]
    private var desiredMutesByIdentifier: [String: Bool] = [:]

    /// 系统级进程默认隐藏
    private let defaultHiddenApps: Set<String> = [
        "com.apple.universalaccessd",
        "com.apple.SiriNCService",
        "com.apple.accessibility.AccessibilityUIServer",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.SystemUIServer",
        "com.apple.coreservices.uiagent",
        "com.apple.AmbientDisplayAgent",
        "com.apple.mediaremoted",
        "com.apple.audio.coreaudiod",
        "coreaudiod",
        "com.apple.hidd",
        "com.apple.corespeech",
        "com.apple.systemsound",
        "loginwindow",
        "PowerChime",
        "SoundMate",
        "com.ivandrew.soundmate.communication",
    ]

    private static let systemDaemonPrefixes: [String] = [
        "com.apple.siri",
        "com.apple.assistant",
        "com.apple.audio",
        "com.apple.coreaudio",
        "com.apple.mediaremote",
        "com.apple.accessibility.heard",
        "com.apple.hearingd",
        "com.apple.voicebankingd",
    ]

    private static let systemDaemonNames: [String] = [
        "systemsoundserverd",
        "coreaudiod",
        "audiomxd",
        "historicalaudiod",
    ]

    init() {
        NSLog("SoundMate: 启动，PID=\(ProcessInfo.processInfo.processIdentifier)")
        communicationExcludedBundleIDs = Set(
            UserDefaults.standard.array(forKey: communicationExcludedDefaultsKey) as? [String] ?? []
        )
        tapManager = AudioTapManagerFactory.create()
        deviceVolume.onStateChange = { [weak self] in
            self?.syncMasterFromDevice()
        }
        deviceVolume.start()
        syncMasterFromDevice()
        startMonitoring()
    }

    /// 把系统输出设备的音量/静音同步到界面
    private func syncMasterFromDevice() {
        masterVolume = deviceVolume.volume
        masterMuted = deviceVolume.isMuted
        canSetMasterVolume = deviceVolume.canSetVolume
        canSetMasterMute = deviceVolume.canSetMute
        inputDevices = deviceVolume.inputDevices
        outputDevices = deviceVolume.outputDevices
        selectedInputDeviceID = deviceVolume.selectedInputDeviceID
        selectedOutputDeviceID = deviceVolume.selectedOutputDeviceID
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        Task {
            await updateAudioApps()
        }

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.updateAudioApps()
                }
            }
            .store(in: &cancellables)

        // 主窗口激活时立即刷新，避免等待下一次自适应轮询。
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.updateAudioApps()
                }
            }
            .store(in: &cancellables)
    }

    /// Reschedules monitoring based on the amount of audio work currently
    /// needed. A one-shot timer avoids keeping a fixed 2-second polling loop
    /// alive while the machine is idle.
    private func scheduleMonitoringTimer() {
        updateTimer?.invalidate()

        let interval: TimeInterval
        if isCommunicationCallProtectionActive || !communicationProtectedPIDs.isEmpty {
            interval = communicationMonitoringInterval
        } else if outputAudioPIDs.isEmpty {
            interval = idleMonitoringInterval
        } else {
            interval = outputMonitoringInterval
        }

        updateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.updateAudioApps()
            }
        }
    }

    /// 更新应用列表：显示当前存在 Core Audio 进程对象的应用。
    /// 是否正在输出单独记录，不用瞬时状态决定应用是否从列表消失。
    func updateAudioApps() async {
        guard !isUpdatingAudioApps else { return }
        isUpdatingAudioApps = true
        defer {
            isUpdatingAudioApps = false
            scheduleMonitoringTimer()
        }

        // Core Audio 的进程属性查询在 macOS 26 上偶尔会阻塞，不能放在主线程。
        let myPID = ProcessInfo.processInfo.processIdentifier
        let queryResult = await Task.detached(priority: .userInitiated) {
            Self.getAudioProcessesUsingHelper(excluding: myPID)
        }.value
        guard let activeProcesses = queryResult else {
            // Core Audio 查询失败或超时时保留现有列表，不要误清空界面。
            return
        }
        let runningApps = NSWorkspace.shared.runningApplications

        var processByPID: [pid_t: AudioProcessRecord] = [:]

        for process in activeProcesses {
            processByPID[process.pid] = process
        }
        let currentAudioPIDs = Set(processByPID.keys)
        let newAudioPIDs = currentAudioPIDs.subtracting(audioPIDs)
        let removedAudioPIDs = audioPIDs.subtracting(currentAudioPIDs)
        audioPIDs = currentAudioPIDs
        outputAudioPIDs = Set(activeProcesses.filter(\.isOutputting).map(\.pid))

        let processSignature = activeProcesses
            .sorted { $0.pid < $1.pid }
            .map { "\($0.pid):\($0.objectID):\($0.isOutputting ? 1 : 0)" }
            .joined(separator: ";")
        let snapshotChanged = processSignature != lastLoggedAudioSignature
        if snapshotChanged {
            NSLog("SoundMate: Core Audio 进程快照 \(activeProcesses.count) 个，正在输出 \(outputAudioPIDs.count) 个，新加入 \(newAudioPIDs.count) 个，移除 \(removedAudioPIDs.count) 个")
            lastLoggedAudioSignature = processSignature
        }

        // 把 Core Audio PID 映射到其宿主主应用，并做 Helper 合并。
        var appGroups: [String: (app: NSRunningApplication?, objectID: AudioObjectID, pids: Set<pid_t>, outputPIDs: Set<pid_t>, inputPIDs: Set<pid_t>)] = [:]

        for (pid, process) in processByPID {
            let objectID = process.objectID
            let directApp = runningApps.first { $0.processIdentifier == pid }
            // Always try parent resolution. NSRunningApplication may expose a
            // Helper bundle as an .app itself, which previously bypassed this step.
            var resolvedApp = findResponsibleApp(for: pid, in: runningApps) ?? directApp

            let rawBundleID = resolvedApp?.bundleIdentifier ?? process.bundleIdentifier ?? objectID.readProcessBundleID()
            let bundleID = Self.stableBundleIdentifier(rawBundleID)
            let localizedName = resolvedApp?.localizedName ?? ""
            var name: String
            if !localizedName.isEmpty {
                name = localizedName
            } else {
                let bundleFallback = objectID.readProcessBundleID()?.components(separatedBy: ".").last ?? ""
                name = bundleFallback.isEmpty ? (processName(for: pid) ?? "Unknown") : bundleFallback
            }

            if isSystemDaemon(bundleID: bundleID, name: name) { continue }

            var groupKey = bundleID ?? name

            // WebKit / Safari 相关进程统一归入 Safari
            if let bid = bundleID, bid == "com.apple.WebKit.GPU" || bid == "com.apple.WebKit.WebContent" || bid == "com.apple.WebKit.Networking" {
                if let safari = runningApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
                    resolvedApp = safari
                    groupKey = safari.bundleIdentifier!
                    if let safariName = safari.localizedName {
                        name = safariName
                    }
                }
            }

            // 通用 Helper / GPU / Service：从 bundleID 逐段去掉后缀匹配宿主（大小写不敏感）
            let lowerName = name.lowercased()
            let isHelperName = lowerName == "gpu"
                || lowerName.contains("helper")
                || lowerName.contains("service")
                || lowerName.contains("webcontent")
                || lowerName.contains("networking")
            let isHelperBundle = bundleID?.lowercased().contains(".helper") == true
                || bundleID?.lowercased().contains(".gpu") == true
                || bundleID?.lowercased().contains(".service") == true
                || bundleID?.lowercased().contains(".webcontent") == true
                || bundleID?.lowercased().contains(".networking") == true

            if isHelperName || isHelperBundle {
                if let bid = bundleID {
                    var parts = bid.components(separatedBy: ".")
                    while parts.count > 1 {
                        parts.removeLast()
                        let candidate = parts.joined(separator: ".")
                        if let parent = runningApps.first(where: { $0.bundleIdentifier == candidate }) {
                            resolvedApp = parent
                            groupKey = candidate
                            break
                        }
                    }
                }
            }

            if var existing = appGroups[groupKey] {
                existing.pids.insert(pid)
                if process.isOutputting {
                    existing.outputPIDs.insert(pid)
                }
                if process.isInputting {
                    existing.inputPIDs.insert(pid)
                }
                appGroups[groupKey] = (existing.app ?? resolvedApp, existing.objectID, existing.pids, existing.outputPIDs, existing.inputPIDs)
            } else {
                appGroups[groupKey] = (
                    resolvedApp,
                    objectID,
                    [pid],
                    process.isOutputting ? [pid] : [],
                    process.isInputting ? [pid] : []
                )
            }
        }

        var newApps: [AudioApp] = []

        for (groupKey, group) in appGroups {
            let app = group.app
            let allPids = group.pids
            let mainObjectID = group.objectID

            let mainPid = (app?.processIdentifier ?? -1) != -1 ? app!.processIdentifier : allPids.first!

            let savedVolume = volumeState.loadSavedVolume(for: mainPid, identifier: groupKey) ?? 1.0
            let savedMute = volumeState.loadSavedMute(for: mainPid, identifier: groupKey) ?? false
            let volume = desiredVolumesByIdentifier[groupKey] ?? savedVolume
            let muted = desiredMutesByIdentifier[groupKey] ?? savedMute
            desiredVolumesByIdentifier[groupKey] = volume
            desiredMutesByIdentifier[groupKey] = muted

            let additional = allPids.subtracting([mainPid])

            let finalName: String
            if let ln = app?.localizedName, !ln.isEmpty {
                finalName = ln
            } else {
                let bundleFallback = groupKey.components(separatedBy: ".").last ?? ""
                finalName = bundleFallback.isEmpty ? (processName(for: mainPid) ?? "Unknown App") : bundleFallback
            }
            let finalIcon = app?.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)

            let audioApp = AudioApp(
                id: mainPid,
                objectID: mainObjectID,
                name: finalName,
                bundleIdentifier: groupKey,
                icon: finalIcon,
                isOutputting: !group.outputPIDs.isEmpty,
                volume: volume,
                isMuted: muted,
                outputPIDs: group.outputPIDs,
                additionalPids: additional
            )

            newApps.append(audioApp)
        }

        newApps.sort(by: Self.appSort)

        if snapshotChanged {
            let groupDescriptions = appGroups
                .map { key, group in
                    let name = group.app?.localizedName ?? key
                    let pids = group.pids.sorted().map(String.init).joined(separator: ",")
                    let outputPIDs = group.outputPIDs.sorted().map(String.init).joined(separator: ",")
                    let inputPIDs = group.inputPIDs.sorted().map(String.init).joined(separator: ",")
                    return "\(name)[\(pids)] 输出=[\(outputPIDs)] 输入=[\(inputPIDs)]"
                }
                .sorted()
                .joined(separator: "; ")
            NSLog("SoundMate: 应用归并结果 \(newApps.count) 个: \(groupDescriptions)")
        }

        // Keep taps only for non-system process objects that are actually
        // outputting. Input-only processes and silent helpers should not keep
        // an aggregate device or real-time IO callback alive.
        let outputtingAppPIDs = Set(newApps.flatMap(\.outputPIDs))
        tapManager?.removeUnusedTaps(keeping: outputtingAppPIDs)

        self.audioApps = newApps

        // 通话候选：同一应用组同时存在输入和输出音频。连续两次观察到
        // 才启动保护，避免录音/直播软件的瞬时输入状态误触发。
        let candidateKeys = Set(appGroups.compactMap { groupKey, group -> String? in
            guard !group.inputPIDs.isEmpty, !group.outputPIDs.isEmpty else { return nil }
            guard !isCommunicationExcluded(groupKey: groupKey, app: group.app) else { return nil }
            return groupKey
        })
        let candidateSignature = candidateKeys.sorted().joined(separator: ";")
        if candidateKeys.isEmpty {
            communicationCandidateSignature = nil
            communicationCandidateCount = 0
        } else if candidateSignature == communicationCandidateSignature {
            communicationCandidateCount += 1
        } else {
            communicationCandidateSignature = candidateSignature
            communicationCandidateCount = 1
        }

        let communicationCallObserved = !candidateKeys.isEmpty && communicationCandidateCount >= 2
        if communicationCallObserved {
            communicationCallHoldUntil = Date().addingTimeInterval(6.0)
            communicationCallAppKeys = candidateKeys
        }
        let communicationCallActive = communicationCallObserved || Date() < communicationCallHoldUntil
        let activeCallKeys = communicationCallActive
            ? communicationCallAppKeys.union(candidateKeys)
            : []
        let nextProtectedPIDs: Set<pid_t> = communicationCallActive
            ? Set(appGroups
                .flatMap { groupKey, group -> [pid_t] in
                    guard !isCommunicationExcluded(groupKey: groupKey, app: group.app) else { return [] }
                    guard activeCallKeys.contains(groupKey) else { return Array(group.outputPIDs) }
                    return group.outputPIDs.filter { pid in
                        guard let process = processByPID[pid] else { return false }
                        return CommunicationRoutingPolicy.protectsCallMedia(
                            ownerBundleID: groupKey,
                            processBundleID: process.bundleIdentifier,
                            processName: processName(for: pid),
                            isInputting: process.isInputting
                        )
                    }
                })
            : []

        for pid in communicationProtectedPIDs.subtracting(nextProtectedPIDs) {
            tapManager?.setCallRouting(for: pid, enabled: false)
        }
        if communicationCallActive {
            for pid in nextProtectedPIDs {
                if !communicationProtectedPIDs.contains(pid) {
                    NSLog("SoundMate: 通话媒体保护 PID=\(pid), bundle=\(processByPID[pid]?.bundleIdentifier ?? "unknown")")
                }
                tapManager?.setCallRouting(for: pid, enabled: true)
            }
        }

        let activeNames = activeCallKeys.compactMap { key in
            appGroups[key]?.app?.localizedName ?? key.components(separatedBy: ".").last
        }
        if communicationCallActive {
            activeCommunicationAppNames = Array(Set(activeNames)).sorted()
        } else {
            activeCommunicationAppNames = []
            communicationCallAppKeys = []
        }
        if communicationCallActive != isCommunicationCallProtectionActive {
            NSLog("SoundMate: 通话保护 \(communicationCallActive ? "开启" : "关闭")，保护应用数=\(nextProtectedPIDs.count)")
        }
        if isCommunicationCallProtectionActive && !communicationCallActive {
            tapManager?.endCallRouting()
        }
        isCommunicationCallProtectionActive = communicationCallActive
        communicationProtectedPIDs = nextProtectedPIDs

        for app in newApps {
            applyEffectiveState(to: app)
        }
    }

    /// 找到一个进程的宿主主应用（用于 Helper / 子进程）
    private func findResponsibleApp(for pid: pid_t, in runningApps: [NSRunningApplication]) -> NSRunningApplication? {
        guard let app = runningApps.first(where: { $0.processIdentifier == pid })
            ?? NSRunningApplication(processIdentifier: pid) else { return nil }
        return parentApp(for: app, in: runningApps) ?? app
    }

    /// 用可执行文件路径取进程名（无 bundle 的进程，如 daemon / CLI）
    private func processName(for pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4096)
        let size = proc_pidpath(pid, &path, 4096)
        guard size > 0 else { return nil }
        let fullPath = String(cString: path)
        return URL(fileURLWithPath: fullPath).lastPathComponent
    }

    // MARK: - Master Controls

    /// 主音量与系统输出设备音量双向同步：拖动滑块即设置设备音量
    func setMasterVolume(_ volume: Float) {
        deviceVolume.setVolume(volume)
    }

    func toggleMasterMute() {
        deviceVolume.setMuted(!deviceVolume.isMuted)
    }

    func selectInputDevice(_ id: AudioObjectID) {
        if !deviceVolume.selectInputDevice(id) {
            syncMasterFromDevice()
        }
    }

    func selectOutputDevice(_ id: AudioObjectID) {
        if !deviceVolume.selectOutputDevice(id) {
            syncMasterFromDevice()
        }
    }

    /// 每个 App 的音量是增益（0-3）：最终响度 = 设备音量 × App 增益
    private func applyEffectiveState(to app: AudioApp) {
        let identifier = stableStateIdentifier(for: app)
        let desiredVolume = desiredVolumesByIdentifier[identifier] ?? app.volume
        let desiredMute = desiredMutesByIdentifier[identifier] ?? app.isMuted

        for pid in app.outputPIDs where outputAudioPIDs.contains(pid) {
            tapManager?.setVolume(for: pid, volume: desiredVolume)
            tapManager?.setMute(for: pid, muted: desiredMute)
        }
    }

    // MARK: - Per-App Controls

    func setVolume(for app: AudioApp, volume: Float) {
        guard let index = audioApps.firstIndex(where: { $0.id == app.id }) else { return }

        let clamped = max(0, min(3.0, volume))
        audioApps[index].volume = clamped

        let identifier = stableStateIdentifier(for: app)
        desiredVolumesByIdentifier[identifier] = clamped
        volumeState.setVolume(for: app.id, to: clamped, identifier: identifier)
        NSLog("SoundMate: 保存应用增益 \(identifier)=\(Int(clamped * 100))%%")

        applyEffectiveState(to: audioApps[index])
    }

    /// 双击音量按钮：将当前 App 音量复位为 100%
    func resetVolume(for app: AudioApp) {
        guard let index = audioApps.firstIndex(where: { $0.id == app.id }) else { return }

        audioApps[index].volume = 1.0

        let identifier = stableStateIdentifier(for: app)
        desiredVolumesByIdentifier[identifier] = 1.0
        volumeState.setVolume(for: app.id, to: 1.0, identifier: identifier)

        applyEffectiveState(to: audioApps[index])
    }

    func toggleMute(for app: AudioApp) {
        guard let index = audioApps.firstIndex(where: { $0.id == app.id }) else { return }

        audioApps[index].isMuted.toggle()
        let isMuted = audioApps[index].isMuted

        let identifier = stableStateIdentifier(for: app)
        desiredMutesByIdentifier[identifier] = isMuted
        volumeState.setMute(for: app.id, to: isMuted, identifier: identifier)

        for pid in app.outputPIDs where outputAudioPIDs.contains(pid) {
            tapManager?.setMute(for: pid, muted: isMuted)
        }
    }

    /// Recreate active taps when audio starts glitching or output state gets stuck.
    func resetAudio() {
        tapManager?.resetAudio()
    }

    // MARK: - Visibility

    var visibleApps: [AudioApp] {
        audioApps
            .filter { !isAppHidden($0) }
            .sorted(by: Self.appSort)
    }

    /// 正在输出的应用置顶；同一状态下按名称、Bundle ID、主 PID 稳定排序。
    private static func appSort(_ lhs: AudioApp, _ rhs: AudioApp) -> Bool {
        if lhs.isOutputting != rhs.isOutputting {
            return lhs.isOutputting && !rhs.isOutputting
        }

        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }

        let lhsBundle = lhs.bundleIdentifier ?? ""
        let rhsBundle = rhs.bundleIdentifier ?? ""
        let bundleOrder = lhsBundle.localizedCaseInsensitiveCompare(rhsBundle)
        if bundleOrder != .orderedSame {
            return bundleOrder == .orderedAscending
        }

        return lhs.id < rhs.id
    }

    private func isAppHidden(_ app: AudioApp) -> Bool {
        let identifier = app.bundleIdentifier ?? app.name
        if let bundleID = app.bundleIdentifier, defaultHiddenApps.contains(bundleID) {
            return true
        }
        if defaultHiddenApps.contains(app.name) {
            return true
        }
        if defaultHiddenApps.contains(identifier) {
            return true
        }
        return false
    }

    var communicationConfigApps: [AudioApp] {
        audioApps
            .filter { !$0.name.isEmpty && !isAppHidden($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func isCommunicationExcluded(_ app: AudioApp) -> Bool {
        communicationExcludedBundleIDs.contains(communicationIdentifier(for: app))
    }

    func setCommunicationExcluded(_ app: AudioApp, excluded: Bool) {
        let identifier = communicationIdentifier(for: app)
        var next = communicationExcludedBundleIDs
        if excluded {
            next.insert(identifier)
        } else {
            next.remove(identifier)
        }
        communicationExcludedBundleIDs = next
        UserDefaults.standard.set(Array(next).sorted(), forKey: communicationExcludedDefaultsKey)
    }

    private func communicationIdentifier(for app: AudioApp) -> String {
        Self.stableBundleIdentifier(app.bundleIdentifier) ?? app.name
    }

    private func isCommunicationExcluded(groupKey: String, app: NSRunningApplication?) -> Bool {
        let identifiers = [
            groupKey,
            app?.bundleIdentifier,
            app?.localizedName
        ].compactMap { $0 }
        let defaultExcluded = Set(["SoundMate"])
        return identifiers.contains {
            defaultExcluded.contains($0)
                || defaultHiddenApps.contains($0)
                || communicationExcludedBundleIDs.contains($0)
        }
    }

    private func stableStateIdentifier(for app: AudioApp) -> String {
        Self.stableBundleIdentifier(app.bundleIdentifier) ?? app.name
    }

    /// 将多进程应用的 Helper Bundle ID 归一到主应用 Bundle ID。
    private static func stableBundleIdentifier(_ bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }

        let lowercased = bundleID.lowercased()
        if lowercased == "com.tencent.flue.wechatappex"
            || lowercased.hasPrefix("com.tencent.flue.wechatappex.") {
            return "com.tencent.xinWeChat"
        }
        if lowercased == "com.microsoft.edgemac.helper"
            || lowercased.hasPrefix("com.microsoft.edgemac.helper.") {
            return "com.microsoft.edgemac"
        }
        return bundleID
    }

    // MARK: - Private Helper Methods

    private nonisolated static func getAudioProcessesUsingHelper(excluding excludedPID: pid_t) -> [AudioProcessRecord]? {
        guard let executableURL = Bundle.main.executableURL else {
            NSLog("SoundMate: 无法找到自身可执行文件，不能枚举 Core Audio 进程")
            return nil
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--enumerate-audio", "--exclude", String(excludedPID)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            NSLog("SoundMate: 启动 Core Audio 枚举 Helper 失败: \(error.localizedDescription)")
            return nil
        }

        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        guard !process.isRunning else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            NSLog("SoundMate: Core Audio 枚举 Helper 超时，已终止子进程")
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            NSLog("SoundMate: Core Audio 枚举 Helper 退出异常，状态码=\(process.terminationStatus)")
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            NSLog("SoundMate: Core Audio 枚举 Helper 输出不是 UTF-8")
            return nil
        }

        var invalidLineCount = 0
        let records = text.split(separator: "\n").compactMap { line -> AudioProcessRecord? in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let pid = pid_t(fields[0]),
                  let objectID = AudioObjectID(fields[1]),
                  let outputFlag = Int(fields[2]) else {
                invalidLineCount += 1
                return nil
            }
            let inputFlag = fields.count >= 4 ? Int(fields[3]) ?? 0 : 0
            let bundleIdentifier = fields.count >= 5 && !fields[4].isEmpty
                ? String(fields[4])
                : nil
            return AudioProcessRecord(
                pid: pid,
                objectID: objectID,
                bundleIdentifier: bundleIdentifier,
                isOutputting: outputFlag != 0,
                isInputting: inputFlag != 0
            )
        }
        if invalidLineCount > 0 {
            NSLog("SoundMate: Core Audio 枚举 Helper 丢弃 \(invalidLineCount) 条格式错误记录")
        }
        return records
    }

    /// 判断一个应用是否为 Helper 子进程，并找到其宿主主应用
    private func parentApp(for app: NSRunningApplication, in runningApps: [NSRunningApplication]) -> NSRunningApplication? {
        let name = app.localizedName ?? ""
        let bundleID = app.bundleIdentifier ?? ""

        // 0. Bundle 路径包含关系：嵌套在主 App 包内的 Helper 归入最近的宿主。
        // 这覆盖 Edge Helper，也覆盖微信等应用的嵌套 Helper
        // 这类 bundle ID 不共享前缀的辅助进程。
        if let appURL = app.bundleURL {
            let appPath = appURL.standardizedFileURL.path
            let pathCandidates = runningApps.compactMap { other -> (NSRunningApplication, Int)? in
                guard other.processIdentifier != app.processIdentifier,
                      let otherURL = other.bundleURL else { return nil }
                let otherPath = otherURL.standardizedFileURL.path
                guard appPath.hasPrefix(otherPath + "/") else { return nil }
                return (other, otherPath.count)
            }
            if let nearest = pathCandidates.max(by: { $0.1 < $1.1 })?.0 {
                return nearest
            }
        }

        // 1. bundleID 前缀包含：子 bundle 归入父应用
        if !bundleID.isEmpty {
            for other in runningApps where other.processIdentifier != app.processIdentifier {
                if let otherBundle = other.bundleIdentifier, !otherBundle.isEmpty, bundleID.hasPrefix(otherBundle + ".") {
                    return other
                }
            }
        }

        let lowerName = name.lowercased()
        let lowerBundle = bundleID.lowercased()
        let isHelper = lowerName.contains("helper")
            || lowerName.contains("gpu")
            || lowerName.contains("service")
            || lowerName == "web content"
            || lowerBundle.contains(".helper")
            || lowerBundle.contains(".webcontent")
            || lowerBundle.contains(".gpu")
            || lowerBundle.contains(".networking")
        guard isHelper else { return nil }

        // 2. 从 bundleID 逐段去掉后缀匹配宿主（com.xxx.YY.Helper → com.xxx.YY）
        if !bundleID.isEmpty {
            var parts = bundleID.components(separatedBy: ".")
            while parts.count > 1 {
                parts.removeLast()
                let candidate = parts.joined(separator: ".")
                if let parent = runningApps.first(where: { $0.processIdentifier != app.processIdentifier && $0.bundleIdentifier == candidate }) {
                    return parent
                }
            }
        }

        // 3. 按名称前缀匹配宿主（如 "哔哩哔哩 Helper" → "哔哩哔哩"）
        for other in runningApps where other.processIdentifier != app.processIdentifier {
            let otherName = other.localizedName ?? ""
            if !otherName.isEmpty, name.hasPrefix(otherName) { return other }
            let otherBundle = other.bundleIdentifier ?? ""
            if !otherBundle.isEmpty, bundleID.hasPrefix(otherBundle) { return other }
        }

        // 4. WebKit 相关进程 → Safari
        if bundleID.hasPrefix("com.apple.WebKit") {
            return runningApps.first { $0.bundleIdentifier == "com.apple.Safari" }
        }

        return nil
    }

    private func isSystemDaemon(bundleID: String?, name: String) -> Bool {
        if let bundleID {
            if Self.systemDaemonPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return true
            }
        }
        let lowercaseName = name.lowercased()
        if Self.systemDaemonNames.contains(where: { lowercaseName.hasPrefix($0) }) {
            return true
        }
        return false
    }
}
