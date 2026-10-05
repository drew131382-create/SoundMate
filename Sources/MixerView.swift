import AppKit
import AVKit
import CoreAudio
import SwiftUI

struct MixerView: View {
    @EnvironmentObject var manager: AudioProcessManager

    private let deviceLabelWidth: CGFloat = 48
    private let devicePickerWidth: CGFloat = 170
    private let devicePickerContentWidth: CGFloat = 140

    var body: some View {
        VStack(spacing: 10) {
            masterSection
            Divider()
            appList
            Divider()
            communicationSettingsSection
            Divider()
            footer
        }
        .padding(12)
        .frame(
            width: 260,
            height: 560
        )
    }

    // MARK: - Audio Devices

    private var masterSection: some View {
        VStack(spacing: 8) {
            HStack {
                Label("音频设备", systemImage: "hifispeaker.2.fill")
                    .font(.headline)
                Spacer()

                Text("隔空播放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AirPlayRoutePicker()
                    .frame(width: 28, height: 24)
                    .help("选择隔空播放设备")
            }

            devicePickerRow(
                title: "输入",
                icon: "mic.fill",
                devices: manager.inputDevices,
                selection: inputDeviceBinding
            )

            devicePickerRow(
                title: "输出",
                icon: "speaker.wave.2.fill",
                devices: manager.outputDevices,
                selection: outputDeviceBinding
            )

            HStack {
                Text("输出设备音量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    manager.toggleMasterMute()
                } label: {
                    Image(systemName: manager.masterMuted ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(manager.masterMuted ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!manager.canSetMasterMute)
                .help(manager.canSetMasterMute ? (manager.masterMuted ? "取消输出设备静音" : "将输出设备静音") : "此设备不支持软件静音")
            }

            HStack {
                Slider(value: masterVolumeBinding, in: 0...1.0)
                    .disabled(!manager.canSetMasterVolume)
                Text(manager.canSetMasterVolume ? "\(Int(manager.masterVolume * 100))%" : "由设备控制")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 66, alignment: .trailing)
            }
        }
    }

    private func devicePickerRow(
        title: String,
        icon: String,
        devices: [AudioDevice],
        selection: Binding<AudioObjectID>
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: deviceLabelWidth, height: 24, alignment: .leading)

            if devices.isEmpty {
                Text("未找到设备")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            } else {
                Spacer(minLength: 0)
                Picker(title, selection: selection) {
                    if !devices.contains(where: { $0.id == selection.wrappedValue }) {
                        Text("未选择")
                            .frame(width: devicePickerContentWidth, alignment: .leading)
                            .tag(AudioObjectID.unknown)
                    }
                    ForEach(devices) { device in
                        Label(device.name, systemImage: device.iconName)
                            .frame(width: devicePickerContentWidth, alignment: .leading)
                            .tag(device.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: devicePickerWidth, height: 24, alignment: .leading)
            }
        }
    }

    private var masterVolumeBinding: Binding<Float> {
        Binding(
            get: { manager.masterVolume },
            set: { manager.setMasterVolume($0) }
        )
    }

    private var inputDeviceBinding: Binding<AudioObjectID> {
        Binding(
            get: { manager.selectedInputDeviceID },
            set: { manager.selectInputDevice($0) }
        )
    }

    private var outputDeviceBinding: Binding<AudioObjectID> {
        Binding(
            get: { manager.selectedOutputDeviceID },
            set: { manager.selectOutputDevice($0) }
        )
    }

    // MARK: - App List

    private var appList: some View {
        Group {
            if manager.visibleApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("暂无可调节的应用")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("拥有音频进程的应用会自动出现在这里")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 150)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(manager.visibleApps.enumerated()), id: \.element.id) { index, app in
                            AppRow(app: app) { newVolume in
                                manager.setVolume(for: app, volume: newVolume)
                            } onToggleMute: {
                                manager.toggleMute(for: app)
                            } onResetVolume: {
                                manager.resetVolume(for: app)
                            }
                            .contextMenu {
                                Button("恢复此应用音频") { manager.resetAudio(for: app) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 150, maxHeight: .infinity)
            }
        }
    }

    private var communicationSettingsSection: some View {
        DisclosureGroup {
            if manager.communicationConfigApps.isEmpty {
                Text("拥有输入和输出音频的应用会显示在这里")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(manager.communicationConfigApps) { app in
                            Toggle(isOn: Binding(
                                get: { !manager.isCommunicationExcluded(app) },
                                set: { enabled in
                                    manager.setCommunicationExcluded(app, excluded: !enabled)
                                }
                            )) {
                                HStack(spacing: 6) {
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .frame(width: 16, height: 16)
                                    }
                                    Text(app.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        } label: {
            Label("通话保护排除名单", systemImage: "phone.badge.waveform")
                .font(.caption)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 7) {
            if let message = manager.audioRecoveryMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .help(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if manager.isCommunicationCallProtectionActive {
                let names = manager.activeCommunicationAppNames.joined(separator: "、")
                Label("\(names.isEmpty ? "通话" : names) 中：SoundMate 正在保持其他应用原音量", systemImage: "phone.badge.waveform.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("退出") {
                    NSApp.terminate(nil)
                }
                .font(.caption)

                Spacer()

                Button("重置音频") { manager.resetAudio() }
                    .font(.caption)
            }
        }
    }
}

// MARK: - AirPlay

/// Apple's system route picker. It presents nearby AirPlay receivers and keeps
/// the route UI consistent with the rest of macOS.
struct AirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: .zero)
        picker.isRoutePickerButtonBordered = true
        picker.setRoutePickerButtonColor(.labelColor, for: .normal)
        picker.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        picker.setAccessibilityLabel("隔空播放")
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

// MARK: - App Row

struct AppRow: View {
    let app: AudioApp
    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void
    let onResetVolume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.fill")
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        onToggleMute()
                    } label: {
                        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(app.isMuted ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(app.isMuted ? "取消静音" : "静音")
                }

                HStack(spacing: 6) {
                    ResetSlider(
                        value: volumeBinding,
                        range: 0...3.0,
                        onVolumeChange: { onVolumeChange($0) },
                        onDoubleClick: { onResetVolume() }
                    )
                    Text("\(Int(app.volume * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var volumeBinding: Binding<Float> {
        Binding(
            get: { app.volume },
            set: { onVolumeChange($0) }
        )
    }
}

// MARK: - 支持双击复位的滑块

/// 封装 NSSlider：拖动调音量，双击将音量复位为 100%
struct ResetSlider: NSViewRepresentable {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let onVolumeChange: (Float) -> Void
    let onDoubleClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = ResetSliderView()
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.isContinuous = true
        slider.controlSize = .mini
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.sliderChanged(_:))
        slider.doubleValue = Double(value)
        slider.onDoubleClick = { [weak coordinator = context.coordinator] in
            coordinator?.didDoubleClick()
        }
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        if abs(Float(nsView.doubleValue) - value) > 0.001 {
            nsView.doubleValue = Double(value)
        }
    }

    final class Coordinator: NSObject {
        var parent: ResetSlider

        init(_ parent: ResetSlider) {
            self.parent = parent
        }

        @objc func sliderChanged(_ sender: NSSlider) {
            parent.onVolumeChange(Float(sender.doubleValue))
        }

        func didDoubleClick() {
            parent.onDoubleClick()
        }
    }
}

/// 检测双击的 NSSlider：双击时触发复位回调，不再移动滑块
final class ResetSliderView: NSSlider {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}
