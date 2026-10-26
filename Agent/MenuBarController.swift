import AppKit
import SwiftUI

/// The agent's menu bar item: a popover with the playback controls.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    let model = MenuBarModel()

    private var statusItem: NSStatusItem?
    private let popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        return popover
    }()
    /// Watches clicks in other apps and on the desktop while the popover is open. `.transient`
    /// alone misses them: the agent is an accessory app and often isn't active.
    private var outsideClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    func install() {
        popover.contentViewController = NSHostingController(rootView: MenuBarView(model: model))
        popover.delegate = self
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        updateIcon()
    }

    func remove() {
        popover.performClose(nil)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func updateIcon() {
        let paused = model.pauseReason != nil
        let image = NSImage(
            systemSymbolName: paused ? "exclamationmark.triangle" : "play.rectangle.fill",
            accessibilityDescription: paused ? "LiveWallpaper paused" : "LiveWallpaper"
        )
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = model.pauseReason?.message ?? "LiveWallpaper"
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // An accessory app has to activate for the popover's controls to take clicks.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            watchForOutsideInteraction()
        }
    }

    private func watchForOutsideInteraction() {
        stopWatching()
        // Global monitors only see other apps' events, so clicks inside the popover (and on
        // the status item, which toggles it) are unaffected. Mouse monitors need no permission.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
    }

    private func stopWatching() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated { stopWatching() }
    }
}
