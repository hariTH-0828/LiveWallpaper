import AppKit

// Background playback agent, launched by launchd via SMAppService. It never
// shows in the Dock and lives independently of LiveWallpaper.app.
let app = NSApplication.shared
// `.accessory`, not `.prohibited`: the Dock only manages Spaces for UI apps, so a
// `.prohibited` process's windows ignore `.canJoinAllSpaces` and stay stuck on the
// Space where they were created.
app.setActivationPolicy(.accessory)

let controller = MainActor.assumeIsolated { WallpaperController() }
MainActor.assumeIsolated { controller.start() }

// launchd sends SIGTERM when the agent is unregistered (the app's Stop) or at logout:
// put the system wallpaper back before going.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    MainActor.assumeIsolated { controller.shutdown() }
    exit(0)
}
termination.resume()

app.run()
