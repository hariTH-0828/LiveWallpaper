import AppKit
import AVFoundation

/// Plays the wallpaper, muted, in one desktop-level window on one screen: either a single
/// video looped, or a folder's .mp4 files one after another, shuffled or in name order.
@MainActor
final class ScreenPlayer {
    let displayID: CGDirectDisplayID
    /// Where this screen starts in a folder played in name order, so screens don't show the same video.
    let orderOffset: Int

    /// Rate to play at, or nil while playback is held back by the power rules.
    var targetRate: Float? = 1 { didSet { applyRate(animated: true) } }
    var shuffle = true
    /// Videos the other screens are showing; the next folder pick avoids them when it can.
    var avoiding: () -> Set<URL> = { [] }
    var onVideoStarted: ((ScreenPlayer, URL) -> Void)?
    var onStateChanged: (() -> Void)?

    private(set) var currentURL: URL?
    private(set) var lastError: String?
    private(set) var screen: NSScreen

    private let player: AVQueuePlayer = {
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        return player
    }()
    private var window: NSWindow?
    /// Takes over drawing from the player layer below 1×, where frames would visibly step.
    private lazy var blendView: FrameBlendView = {
        let view = FrameBlendView(frame: .zero)
        view.player = player
        view.autoresizingMask = [.width, .height]
        return view
    }()
    /// Eases the rate to a new target instead of jumping.
    private var rampTimer: Timer?
    private let rampDuration: TimeInterval = 0.8
    /// The last speed asked for, kept while paused so blending stays as it was.
    private var speed: Float = 1

    /// Set in single-video mode.
    private var looper: AVPlayerLooper?
    /// Set in folder mode.
    private(set) var folderURL: URL?
    private var queue: [URL] = []
    /// Last video that played to the end, so a new round doesn't repeat it straight away.
    private var lastPlayedURL: URL?
    private var failuresInARow = 0
    private var itemStatusObservation: NSKeyValueObservation?
    /// The folder item we started. Tracked here because AVQueuePlayer drops failed items,
    /// so `player.currentItem` is already nil by the time the failure arrives.
    private var folderItem: AVPlayerItem?
    /// Watchdog: a folder video whose position doesn't move for `stallTimeout` is skipped.
    private var lastProgress: (time: Double, at: Date)?
    private let stallTimeout: TimeInterval = 5

    init(screen: NSScreen, displayID: CGDirectDisplayID, orderOffset: Int) {
        self.screen = screen
        self.displayID = displayID
        self.orderOffset = orderOffset
    }

    // MARK: - Playback

    func playSingle(_ url: URL) {
        reset()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        show(url)
    }

    func playFolder(_ url: URL) {
        reset()
        folderURL = url
        playNextInFolder()
    }

    /// True when already looping `url`, so a reload can leave it alone.
    func isLooping(_ url: URL) -> Bool {
        looper != nil && looper?.status != .failed && currentURL == url
    }

    /// Forgets the queue so the next pick follows the current `shuffle` setting.
    func resetQueue() {
        queue = []
    }

    /// Rescans from the next pick; a current video that was deleted is skipped straight away.
    func syncFolder() {
        guard folderURL != nil else { return }
        queue = []
        failuresInARow = 0
        lastError = nil
        if let currentURL, !FileManager.default.fileExists(atPath: currentURL.path) {
            playNextInFolder()
        }
    }

    func stop() {
        reset()
        hide()
    }

    private func playNextInFolder() {
        guard let folderURL else { return }

        if queue.isEmpty {
            // Rescan at the start of every round so added and removed files are picked up.
            do {
                queue = try newRound(from: FolderScanner.videos(in: folderURL))
                lastError = nil
            } catch {
                lastError = "Can't read \(folderURL.path): \(error.localizedDescription)"
                queue = []
            }
        }
        guard !queue.isEmpty else {
            if lastError == nil { lastError = "No .mp4 videos in \(folderURL.path)" }
            hide()
            return
        }

        let busy = avoiding()
        let url = queue.remove(at: queue.firstIndex { !busy.contains($0) } ?? 0)
        let item = AVPlayerItem(url: url)
        itemStatusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.itemEnded(item, failed: true) }
            }
        }
        folderItem = item
        lastProgress = nil
        player.removeAllItems()
        player.insert(item, after: nil)
        show(url)
    }

    private func newRound(from videos: [URL]) -> [URL] {
        guard !videos.isEmpty else { return [] }
        if shuffle {
            var round = videos.shuffled()
            // Don't play the same video twice in a row across a reshuffle.
            if round.count > 1, round.first == lastPlayedURL {
                round.swapAt(0, round.count - 1)
            }
            return round
        }
        // Name order, carrying on after the last video, or from this screen's offset.
        let start = lastPlayedURL.flatMap { videos.firstIndex(of: $0) }.map { $0 + 1 } ?? orderOffset
        let index = start % videos.count
        return Array(videos[index...] + videos[..<index])
    }

    /// Handles end and failure notifications; items from other screens or from before a reload are ignored.
    func itemEnded(_ item: AVPlayerItem?, failed: Bool) {
        guard let folderURL, let item, item === folderItem else { return }

        if failed {
            failuresInARow += 1
            lastError = "Skipped unplayable \(currentURL?.lastPathComponent ?? "video")"
            // Every file in a full round failed: stop rather than spin.
            let roundSize = ((try? FolderScanner.videos(in: folderURL)) ?? []).count
            if failuresInARow >= max(roundSize, 1) {
                lastError = "No playable .mp4 videos in \(folderURL.path)"
                hide()
                return
            }
        } else {
            failuresInARow = 0
            lastPlayedURL = currentURL
        }
        playNextInFolder()
    }

    // MARK: - Health

    /// Restarts playback that died, and skips folder videos that stopped moving.
    /// Called from the agent's heartbeat and after wake.
    func checkHealth() {
        if let looper, let url = currentURL,
           looper.status == .failed || player.currentItem?.status == .failed {
            if FileManager.default.fileExists(atPath: url.path) {
                playSingle(url)
            } else {
                stop()
                lastError = "Video not found: \(url.path)"
            }
            return
        }
        guard let rate = targetRate, currentURL != nil, rampTimer == nil else { return }
        if player.rate == 0 { player.rate = rate }
        skipIfStalled()
    }

    /// Clears what a long sleep leaves behind: a stale stall timer, a folder given up on
    /// while nothing could play, and a player layer that no longer draws.
    func recover() {
        lastProgress = nil
        if folderURL != nil, currentURL == nil {
            failuresInARow = 0
            playNextInFolder()
        }
        rebuildWindow()
        applyRate(animated: false)
    }

    /// Some broken files never report a failure; they just sit at 0 with rate 1.
    private func skipIfStalled() {
        guard let item = folderItem else { return }
        let now = CMTimeGetSeconds(player.currentTime())
        if let last = lastProgress, abs(now - last.time) < 0.01 {
            if Date().timeIntervalSince(last.at) >= stallTimeout {
                itemEnded(item, failed: true)
            }
        } else {
            lastProgress = (now, Date())
        }
    }

    // MARK: - State

    var status: ScreenStatus {
        let seconds = CMTimeGetSeconds(player.currentTime())
        return ScreenStatus(
            displayID: displayID,
            videoPath: currentURL?.path,
            currentTime: seconds.isFinite ? seconds : 0,
            rate: player.rate
        )
    }

    var isShowing: Bool { window != nil }

    /// Moves the player to `targetRate`, eased over `rampDuration` when `animated`; nil pauses.
    private func applyRate(animated: Bool) {
        rampTimer?.invalidate()
        rampTimer = nil
        if let targetRate {
            speed = targetRate
            player.defaultRate = targetRate
        }
        lastProgress = nil

        let from = player.rate
        let to = currentURL == nil ? 0 : (targetRate ?? 0)
        guard animated, currentURL != nil, abs(from - to) > 0.01 else {
            setRate(to)
            updateBlending()
            return
        }

        // Blend for the whole ramp whenever either end of it is below 1×.
        blendView.isActive = window != nil && min(from == 0 ? speed : from, to == 0 ? speed : to) < 1
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let progress = min(Date().timeIntervalSince(start) / self.rampDuration, 1)
                let eased = Float(progress * progress * (3 - 2 * progress))
                self.setRate(from + (to - from) * eased)
                if progress >= 1 {
                    timer.invalidate()
                    self.rampTimer = nil
                    self.lastProgress = nil
                    self.updateBlending()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rampTimer = timer
    }

    private func setRate(_ rate: Float) {
        if rate <= 0 {
            player.pause()
        } else {
            player.rate = rate
        }
    }

    private func updateBlending() {
        blendView.isActive = window != nil && currentURL != nil && speed < 1
    }

    private func reset() {
        looper?.disableLooping()
        looper = nil
        itemStatusObservation = nil
        folderItem = nil
        lastProgress = nil
        lastPlayedURL = nil
        folderURL = nil
        queue = []
        failuresInARow = 0
        lastError = nil
        player.pause()
        player.removeAllItems()
    }

    private func show(_ url: URL) {
        currentURL = url
        if window == nil { rebuildWindow() }
        applyRate(animated: false)
        onVideoStarted?(self, url)
        onStateChanged?()
    }

    private func hide() {
        rampTimer?.invalidate()
        rampTimer = nil
        player.pause()
        currentURL = nil
        closeWindow()
        onStateChanged?()
    }

    // MARK: - Window

    func move(to screen: NSScreen) {
        self.screen = screen
        guard let window, window.frame != screen.frame else { return }
        window.setFrame(screen.frame, display: true)
    }

    func orderFront() {
        window?.orderFrontRegardless()
    }

    func tearDown() {
        stop()
        player.replaceCurrentItem(with: nil)
    }

    private func closeWindow() {
        blendView.isActive = false
        blendView.removeFromSuperview()
        window?.close()
        window = nil
    }

    /// A fresh window and player layer; after a long sleep the old layer can stop drawing.
    private func rebuildWindow() {
        closeWindow()
        guard currentURL != nil else { return }

        let window = NSWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.setFrame(screen.frame, display: false)

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = content.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.layer?.addSublayer(playerLayer)
        blendView.frame = content.bounds
        content.addSubview(blendView)
        window.contentView = content

        window.orderFrontRegardless()
        self.window = window
        updateBlending()
    }
}
