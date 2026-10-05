# SoundMate

这是 SoundMate 的通用语音/视频通话保护版本，应用显示名称为 SoundMate，使用独立的 Bundle ID：
`com.ivandrew.soundmate.communication`。

安装后的应用名称为 `SoundMate.app`；Bundle ID、Target 和可执行文件名均已统一为 SoundMate。

SoundMate 与普通应用音量调节工具的核心区别，是专门解决通话过程中 macOS 自动压低其他发声软件音量的问题：通话时保持音乐、视频和系统声音的正常音量，不靠数字增益硬拉，因此避免额外失真。

这是一个菜单栏 macOS 应用，启动后常驻菜单栏、不出现在 Dock 中。点击菜单栏的 SoundMate 图标即可在图标下方打开或隐藏原生状态栏弹窗；点击弹窗外部会自动关闭，但不会停止通话保护，使用弹窗中的“退出”按钮才会结束应用。

特点：

- 以菜单栏状态项常驻，点击图标显示紧凑的原生状态栏弹窗，并提供标准 macOS 应用菜单。
- 保留 Core Audio 多进程枚举、Helper 归并和独立音量控制功能。
- 任意用户应用同时使用输入和输出音频并持续被检测到时，自动识别为语音/视频通话；支持 Zoom、Teams、Discord、FaceTime、微信等应用。
- 通话期间为其他应用启用独立路由；各应用保存的音量设置保持不变。设备级 ducking 恢复可能影响同一输出设备上的所有应用，并非按应用关闭 ducking。
- 微信通话期间，额外保护只输出音频的 `WeChatAppEx`、`WeChatHelper` 和 `wxplayer` 媒体进程。微信主通话进程及正在使用输入音频的进程仍排除，避免整组排除微信后视频号、语音消息遗漏保护；通话结束时会释放全部通话专用路由，用户排除名单继续生效。
- 应用启动时不创建视频应用 Tap，也不写入系统 ducking 属性；只有检测到通话并存在待保护的媒体进程时才启用恢复循环。
- 通话保护保持用户原有增益，不再根据音乐电平自动放大，不再叠加第二次限幅；排除名单可在主窗口配置。
- 通过独立音频 Tap 路由播放；通话期间尝试恢复设备的临时 ducking 系数。HAL 的 `duck` 属性未公开文档，仅在存在、可写且数据长度符合预期时使用；不支持或写入失败会记录日志，不会退回倍增补偿。接口调用成功不等于实际通话效果已验证。
- 通话结束后停止设备恢复操作，释放通话专用 Tap，并刷新仍需独立音量控制的媒体路由，保留用户设置。
- 音频路由使用版本号取消过期重建，校验 Core Audio 进程对象；设备格式变化、切换输出和睡眠唤醒时刷新路由。
- 播放期间检查回调和有效缓冲进度，异常时有限重建；连续失败后释放接管并提示。静音片段、暂停、主动静音和 0% 音量不会仅因电平为零触发恢复。
- 右键应用行可选择“恢复此应用音频”，底部“重置音频”可恢复全部路由。普通媒体进入旁路时按系统原音量播放，响度可能高于保存的应用增益；保存设置不变。
- 蓝牙耳机麦克风引起的传输音质下降无法由本功能修复；可在通话软件中选择 Mac 内置麦克风。需要以实际微信通话确认设备兼容性。
- 主窗口可直接选择系统默认输入、输出设备，并控制当前输出设备支持的硬件音量和静音。
- 内置系统隔空播放设备选择按钮。

设备属性的调查参考：[Unduck-Pro 的设备 ducking 实现](https://github.com/MrRockySL/Unduck-Pro/blob/main/Sources/DuckAudioCore/PerAppTapEngine.swift)。这里的 `duck` 属性并非 Apple 公开支持的 API，不能保证未来系统版本兼容。

## 验证

2026-10-05 音频恢复改动通过自动故障测试与 arm64 + x86_64 Release 编译。故障测试覆盖通话结束保留音量、静音、旧任务取消、同 PID 对象变化、释放失败、有限重试、回调停滞、暂停、过期健康回调和应用关闭；缓冲测试覆盖立体声、分离声道、蓝牙单声道和缓冲尾部清零。

```bash
bash Tests/run.sh
```

本次改动尚未通过真实微信通话及各类耳机回归。检查回调有效不等于实际设备已经出声。Core Audio API 阻塞的工作进程隔离、完整设备矩阵和诊断导出仍在后续方案中，不能承诺所有设备永不无声或固定时间内恢复。详细状态见 [音频恢复方案](docs/audio-recovery-plan.md)。

退出旧版后打开 `SoundMate.app`，将以前为补偿而调高的应用滑块恢复到 100%。播放同一段音乐，比较微信通话前、通话中和结束后的响度及音质。也需检查静音、通话中切换输出设备，以及未授权音频捕获时的表现。

已通过信号测试和 arm64 编译；当前默认输出设备的 `duck` 属性存在、可写且为 16 字节。2026-09-07 在当前电脑进行微信通话回归，用户确认视频号恢复声音、其他媒体防压低及通话声音正常。该结果仅覆盖本次实际设备与应用版本。查看日志中的 `Device ducking restore` 可分辨属性被支持还是只启用了原音路由。

微信媒体进程选择回归测试：

```bash
swiftc -O Tests/CommunicationRoutingTests.swift Sources/CommunicationRoutingPolicy.swift -o build/CommunicationRoutingTests
./build/CommunicationRoutingTests
```

## 构建

在 Xcode 中打开 `SoundMate.xcodeproj`，或使用：

```bash
xcodegen generate --spec project.yml
xcodebuild -project SoundMate.xcodeproj -scheme SoundMate -configuration Release build
```

当前工程默认生成 `arm64 + x86_64` Universal 版本，最低支持 macOS 14.2。
