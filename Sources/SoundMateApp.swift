import AppKit
import Darwin
import SwiftUI

/// AppKit entry point for the menu-bar SoundMate app.
@main
@MainActor
enum SoundMateApp {
    static func main() {
        AudioProcessEnumerator.runCommandLineModeIfNeeded()

        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(
               withBundleIdentifier: bundleID
           ).first(where: { $0.processIdentifier != currentPID }) {
            NSLog("SoundMate: 已有实例 PID=%d，当前实例退出", existing.processIdentifier)
            existing.activate(options: [.activateIgnoringOtherApps])
            Darwin.exit(0)
        }

        let application = NSApplication.shared
        let delegate = SoundMateAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
private final class SoundMateAppDelegate: NSObject, NSApplicationDelegate {
    private var manager: AudioProcessManager?
    private var popover: NSPopover?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()

        let manager = AudioProcessManager()
        self.manager = manager

        configureStatusItem()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 260, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: MixerView().environmentObject(manager)
        )
        self.popover = popover
        NSLog("SoundMate: 菜单栏状态项和原生弹窗已创建")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager else { return .terminateNow }
        manager.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        popover?.performClose(nil)
        popover?.contentViewController = nil
        popover = nil
        statusItem = nil
        manager = nil
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "waveform.circle.fill",
                accessibilityDescription: "SoundMate"
            )
            button.image?.isTemplate = true
            button.toolTip = "SoundMate 音频保护"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(sender)
            return
        }

        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "SoundMate")
        appMenu.addItem(
            withTitle: "About SoundMate",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide SoundMate",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(
            withTitle: "隐藏其他应用",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(
            withTitle: "显示全部",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit SoundMate",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.miniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: "缩放",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "将所有窗口置于最前",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
