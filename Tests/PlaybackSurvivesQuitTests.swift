import AppKit
import XCTest

/// End-to-end: import through the real app, quit it, and check that the
/// launchd-managed agent keeps playing the video on the desktop.
final class PlaybackSurvivesQuitTests: XCTestCase {
    private let bundleID = "com.hari.LiveWallpaper"
    private let paths = WallpaperPaths.default
    private var tempDir: URL!
    private var agentPID: pid_t?

    private var appURL: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("LiveWallpaper.app")
    }

    override func setUpWithError() throws {
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: paths.config.path),
            "A wallpaper is already registered at \(paths.config.path); stop it in the app before running this test."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path), "LiveWallpaper.app not built at \(appURL.path)")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackSurvivesQuitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if FileManager.default.fileExists(atPath: appURL.path) {
            if let app = try? await launchApp(arguments: ["--unregister"]) {
                _ = await waitUntil(timeout: 10) { app.isTerminated }
            }
        }
        if let agentPID, kill(agentPID, 0) == 0 {
            kill(agentPID, SIGTERM)
        }
        WallpaperStore().clear()
        try? FileManager.default.removeItem(at: paths.status)
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testPlaybackContinuesAfterAppQuits() async throws {
        // 10 s clip at 10 fps: long enough that the samples below can't land on the same loop position.
        let movie = try await VideoFixture.makeMovie(in: tempDir, frames: 100, fps: 10)
        let launchedAt = Date()

        // 1. Import + register through the real app bundle.
        let app = try await launchApp(arguments: ["--import", movie.path])
        let appPID = app.processIdentifier

        // 2. Wait until the agent reports it is playing the imported copy.
        guard let playing = await waitForPlayback(after: launchedAt) else {
            app.forceTerminate()
            return XCTFail("""
                Agent never reported playback. If this is the first run, approve LiveWallpaper in \
                System Settings › General › Login Items and re-run.
                launchctl: \(launchctlSummary())
                """)
        }
        agentPID = playing.pid
        XCTAssertNotEqual(playing.pid, appPID, "playback must run outside the app process")

        // 3. Quit the main app the normal way.
        XCTAssertTrue(app.terminate())
        let quit = await waitUntil(timeout: 10) { app.isTerminated }
        if !quit { app.forceTerminate() }
        XCTAssertTrue(quit, "app did not quit")
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty)

        // 4. The agent process is still alive…
        XCTAssertEqual(kill(playing.pid, 0), 0, "agent process died with the app")

        // 5. …and still advancing playback.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let first = try XCTUnwrap(JSONFile.read(AgentStatus.self, from: paths.status))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let second = try XCTUnwrap(JSONFile.read(AgentStatus.self, from: paths.status))

        XCTAssertEqual(second.pid, playing.pid, "agent was restarted rather than kept running")
        XCTAssertGreaterThan(second.updatedAt, first.updatedAt, "heartbeat stopped")
        XCTAssertGreaterThan(second.rate, 0, "player is paused")
        // The clip loops, so time may wrap; it just must have moved.
        XCTAssertNotEqual(second.currentTime, first.currentTime, accuracy: 0.5, "playback position is frozen")
        XCTAssertEqual(second.videoPath, playing.videoPath)

        // 6. Independently of the agent's own report, the window server is actually showing a
        //    desktop-level agent window on the current Space for every display. Existing is not
        //    enough: a window stuck on another Space exists but is never seen.
        XCTAssertEqual(visibleAgentWindowCount(pid: playing.pid), NSScreen.screens.count,
                       "expected one visible desktop-level agent window per display")
    }

    /// Stand-in for a restart: with the app not running, launchd kills the agent and starts a
    /// fresh one, exactly as it does at login. The new agent must resume from config.json alone.
    func testAgentResumesWhenRelaunchedByLaunchd() async throws {
        let movie = try await VideoFixture.makeMovie(in: tempDir, frames: 100, fps: 10)
        let launchedAt = Date()
        let app = try await launchApp(arguments: ["--import", movie.path])
        let first = await waitForPlayback(after: launchedAt)
        guard let first else {
            app.forceTerminate()
            return XCTFail("Agent never reported playback.\nlaunchctl: \(launchctlSummary())")
        }
        agentPID = first.pid
        XCTAssertTrue(app.terminate())
        _ = await waitUntil(timeout: 10) { app.isTerminated }

        let relaunchedAt = Date()
        XCTAssertEqual(runLaunchctl(["kickstart", "-k", "gui/\(getuid())/com.hari.LiveWallpaper.Agent"]), 0)

        let resumed = await waitForPlayback(after: relaunchedAt)
        let status = try XCTUnwrap(resumed, "agent did not resume after relaunch")
        agentPID = status.pid
        XCTAssertNotEqual(status.pid, first.pid, "expected a fresh agent process")
        XCTAssertEqual(status.videoPath, first.videoPath)
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty)
        XCTAssertEqual(visibleAgentWindowCount(pid: status.pid), NSScreen.screens.count)
    }

    // MARK: - Helpers

    /// Waits for a heartbeat newer than `date` that shows the registered video playing on screen.
    private func waitForPlayback(after date: Date, timeout: TimeInterval = 20) async -> AgentStatus? {
        var playing: AgentStatus?
        _ = await waitUntil(timeout: timeout) { [paths] in
            guard let config = JSONFile.read(WallpaperConfig.self, from: paths.config),
                  let status = JSONFile.read(AgentStatus.self, from: paths.status),
                  status.updatedAt > date,
                  status.videoPath == config.videoPath,
                  status.rate > 0, status.windowCount >= 1
            else { return false }
            playing = status
            return true
        }
        return playing
    }

    private func visibleAgentWindowCount(pid: pid_t) -> Int {
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let onScreen = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
        return onScreen.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid
                && ($0[kCGWindowLayer as String] as? Int) == desktopLevel
        }.count
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func launchApp(arguments: [String]) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        return try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return condition()
    }

    private func launchctlSummary() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/com.hari.LiveWallpaper.Agent"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").prefix(15).joined(separator: "\n")
    }
}
