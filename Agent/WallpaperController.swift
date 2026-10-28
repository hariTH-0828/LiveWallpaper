import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Plays the registered wallpaper on every screen, each through its own `ScreenPlayer`: either
/// one video looped everywhere, or a folder's .mp4 files with every screen picking its own.
/// Runs regardless of lock, display sleep or covered desktops; only the power rules pause it.
@MainActor
final class WallpaperController {
    private let paths: WallpaperPaths = .default
    private let store = WallpaperStore()
    private var players: [CGDirectDisplayID: ScreenPlayer] = [:]
    private var config: WallpaperConfig?
    private var settings: PlaybackSettings
    private var pauseReason: PauseReason?
    private var lastError: String?
    /// Displays are off; the stall watchdog would mistake that for broken videos.
    private var screensAsleep = false

    private let power = PowerMonitor()
    private let menuBar = MenuBarController()
    private let systemWallpaper: SystemWallpaper
    /// Plays the main screen's video on the lock screen; nil before macOS 26, where the
    /// lock screen gets `systemWallpaper`'s stills instead.
    private let aerial: AerialLockScreen?
    private var statusTimer: Timer?
    private var activity: NSObjectProtocol?

    init() {
        settings = (JSONFile.read(PlaybackSettings.self, from: paths.settings) ?? PlaybackSettings()).normalized
        systemWallpaper = SystemWallpaper(paths: paths)
        aerial = AerialLockScreen(paths: paths)
    }

    func start() {
        // Keep the heartbeat timer and playback from being throttled by App Nap.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Playing live wallpaper"
        )

        DistributedNotificationCenter.default().addObserver(
            forName: WallpaperNotifications.reload, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncScreens() }
        }
        // Belt and braces for Space switches: make sure our windows are ordered in on the new Space.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.players.values.forEach { $0.orderFront() } }
        }
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.itemEnded(note.object as? AVPlayerItem, failed: false) }
        }
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.itemEnded(note.object as? AVPlayerItem, failed: true) }
        }
        observeSleepAndWake()

        if let aerial {
            // Stills left from before the Aerial took over the lock screen.
            if FileManager.default.fileExists(atPath: paths.originalDesktop.path) {
                systemWallpaper.restore()
            }
            aerial.reapplySelection()
        }

        power.onChange = { [weak self] in self?.updatePlayback() }
        power.start()
        installMenuBar()

        syncScreens()
        reload(force: true)
        updatePlayback()

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        writeStatus()
    }

    /// Tears playback down and gives the screens their own wallpaper back. Used by Quit and on SIGTERM.
    func shutdown() {
        statusTimer?.invalidate()
        statusTimer = nil
        players.values.forEach { $0.tearDown() }
        players.removeAll()
        restoreLockScreen()
        writeStatus()
    }

    // MARK: - Config

    private func reload(force: Bool = false) {
        guard let config = JSONFile.read(WallpaperConfig.self, from: paths.config) else {
            self.config = nil
            players.values.forEach { $0.stop() }
            restoreLockScreen()
            updateMenu()
            writeStatus()
            return
        }
        self.config = config
        lastError = nil

        if config.folderURL == nil, !FileManager.default.fileExists(atPath: config.videoPath) {
            lastError = "Video not found: \(config.videoPath)"
            players.values.forEach { $0.stop() }
        } else {
            for player in orderedPlayers {
                // A folder always restarts, so re-choosing it picks up its current contents.
                if force || config.folderURL != nil || !player.isLooping(config.videoURL) {
                    startPlaying(player)
                }
            }
        }
        updateMenu()
        writeStatus()
    }

    private func startPlaying(_ player: ScreenPlayer) {
        guard let config else { return }
        if let folder = config.folderURL {
            player.playFolder(folder)
        } else if FileManager.default.fileExists(atPath: config.videoPath) {
            player.playSingle(config.videoURL)
        }
    }

    private func itemEnded(_ item: AVPlayerItem?, failed: Bool) {
        players.values.forEach { $0.itemEnded(item, failed: failed) }
    }

    // MARK: - Screens

    /// Main display first, so it gets the first pick of a folder.
    private var orderedPlayers: [ScreenPlayer] {
        players.values.sorted { $0.orderOffset < $1.orderOffset }
    }

    /// One player per display: new displays start playing, removed ones are torn down and
    /// moved ones are resized. Screen-parameter notifications also fire for menu bar and Dock
    /// changes, which leave everything as it is.
    private func syncScreens() {
        let screens = NSScreen.screens
        var present = Set<CGDirectDisplayID>()
        for (index, screen) in screens.enumerated() {
            guard let id = screen.displayID else { continue }
            present.insert(id)
            if let player = players[id] {
                player.move(to: screen)
            } else {
                let player = makePlayer(for: screen, displayID: id, orderOffset: index)
                players[id] = player
                startPlaying(player)
            }
        }
        for (id, player) in players where !present.contains(id) {
            player.tearDown()
            players[id] = nil
        }
    }

    private func makePlayer(for screen: NSScreen, displayID: CGDirectDisplayID, orderOffset: Int) -> ScreenPlayer {
        let player = ScreenPlayer(screen: screen, displayID: displayID, orderOffset: orderOffset)
        player.shuffle = settings.shuffle
        player.targetRate = pauseReason == nil ? settings.speed : nil
        player.avoiding = { [weak self, weak player] in
            guard let self else { return [] }
            return Set(self.players.values.filter { $0 !== player }.compactMap(\.currentURL))
        }
        player.onVideoStarted = { [weak self] player, url in
            guard let self else { return }
            if let aerial = self.aerial {
                // The lock screen shows one video: whatever the main screen is playing.
                if player.displayID == NSScreen.screens.first?.displayID { aerial.install(url) }
            } else {
                self.systemWallpaper.setStill(from: url, on: player.screen)
            }
        }
        player.onStateChanged = { [weak self] in self?.updateMenu() }
        return player
    }

    private func restoreLockScreen() {
        if let aerial {
            aerial.restore()
        } else {
            systemWallpaper.restore()
        }
    }

    // MARK: - Sleep and wake

    private func observeSleepAndWake() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensAsleep = true }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recover() }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover() }
        }
    }

    /// After a long lock or sleep, displays can come back with players that stopped, folders
    /// given up on, and layers that no longer draw. Rebuild what's needed and play again,
    /// then check once more when late displays have reattached.
    private func recover() {
        screensAsleep = false
        syncScreens()
        for player in orderedPlayers {
            player.recover()
            if player.currentURL == nil { startPlaying(player) }
        }
        updatePlayback()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncScreens()
                for player in self.orderedPlayers {
                    if player.currentURL == nil { self.startPlaying(player) }
                    player.checkHealth()
                    player.orderFront()
                }
            }
        }
    }

    private func heartbeat() {
        // A missed wake notification would otherwise leave the watchdog off for good.
        if screensAsleep, CGDisplayIsAsleep(CGMainDisplayID()) == 0 {
            recover()
        }
        if players.count != NSScreen.screens.count {
            syncScreens()
        }
        if !screensAsleep {
            players.values.forEach { $0.checkHealth() }
        }
        writeStatus()
    }

    // MARK: - Settings and power

    func apply(_ newSettings: PlaybackSettings) {
        let shuffleChanged = newSettings.shuffle != settings.shuffle
        settings = newSettings
        try? paths.ensureDirectories()
        try? JSONFile.write(settings, to: paths.settings)
        for player in players.values {
            player.shuffle = settings.shuffle
            // Takes effect from each screen's next video, without cutting the current one.
            if shuffleChanged { player.resetQueue() }
        }
        updatePlayback()
    }

    /// Low Power Mode always pauses; "On power adapter" also pauses on battery.
    private func updatePlayback() {
        if power.isLowPowerMode {
            pauseReason = .lowPowerMode
        } else if settings.runMode == .onPowerAdapter, !power.isOnPowerAdapter {
            pauseReason = .onBattery
        } else {
            pauseReason = nil
        }
        players.values.forEach { $0.targetRate = pauseReason == nil ? settings.speed : nil }
        updateMenu()
        writeStatus()
    }

    // MARK: - Menu bar

    private func installMenuBar() {
        let model = menuBar.model
        model.onSettingsChanged = { [weak self] in self?.apply($0) }
        model.onChooseVideo = { [weak self] in self?.choose(folder: false) }
        model.onChooseFolder = { [weak self] in self?.choose(folder: true) }
        model.onSyncFolder = { [weak self] in self?.syncFolder() }
        model.onQuit = { [weak self] in self?.quit() }
        menuBar.install()
        updateMenu()
    }

    private func updateMenu() {
        let model = menuBar.model
        if model.settings != settings { model.settings = settings }
        model.pauseReason = pauseReason
        model.isFolderMode = config?.folderURL != nil

        var description: String
        if let config {
            if let folder = config.folderURL {
                let counts = FolderScanner.counts(in: folder)
                description = "\(folder.lastPathComponent) — \(counts.playable) video\(counts.playable == 1 ? "" : "s")"
                if players.count > 1 { description += " on \(players.count) screens" }
                if counts.tooLong > 0 { description += " (\(counts.tooLong) over 1 min skipped)" }
            } else {
                description = config.videoURL.lastPathComponent
            }
        } else {
            description = "No wallpaper chosen"
        }
        if let error = lastError ?? orderedPlayers.compactMap(\.lastError).first {
            description += "\n\(error)"
        }
        model.currentDescription = description
        menuBar.updateIcon()
    }

    /// Picks up videos added to or removed from the folder without cutting off what's playing.
    private func syncFolder() {
        guard config?.folderURL != nil else { return }
        for player in orderedPlayers {
            player.syncFolder()
            if player.currentURL == nil { startPlaying(player) }
        }
        updateMenu()
        writeStatus()
    }

    private func choose(folder: Bool) {
        menuBar.closePopover()
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.allowsMultipleSelection = false
        if folder {
            panel.message = "Choose a folder of .mp4 videos to shuffle"
        } else {
            panel.allowedContentTypes = [.movie]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                if folder {
                    _ = try await store.importFolder(from: url)
                } else {
                    _ = try await store.importVideo(from: url)
                }
                reload(force: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't set wallpaper"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    /// Stops playback, restores the system wallpaper and stops this agent for good: it is
    /// unregistered from launchd, and exiting cleanly keeps launchd from restarting it.
    private func quit() {
        shutdown()
        menuBar.remove()
        try? WallpaperRegistrar.unregister()
        exit(0)
    }

    // MARK: - Status

    private func writeStatus() {
        let screens = orderedPlayers.map(\.status)
        let main = screens.first
        let status = AgentStatus(
            pid: ProcessInfo.processInfo.processIdentifier,
            videoPath: main?.videoPath,
            currentTime: main?.currentTime ?? 0,
            rate: main?.rate ?? 0,
            windowCount: players.values.filter(\.isShowing).count,
            updatedAt: Date(),
            folderPath: config?.folderURL?.path,
            lastError: lastError ?? orderedPlayers.compactMap(\.lastError).first,
            screens: screens,
            pauseReason: pauseReason?.rawValue
        )
        try? paths.ensureDirectories()
        try? JSONFile.write(status, to: paths.status)
    }
}
