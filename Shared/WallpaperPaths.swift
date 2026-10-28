import Foundation

/// Locations of the state shared between the app and the playback agent.
struct WallpaperPaths {
    let root: URL

    static let `default` = WallpaperPaths(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
    )

    var videos: URL { root.appendingPathComponent("Videos", isDirectory: true) }
    var config: URL { root.appendingPathComponent("config.json") }
    var status: URL { root.appendingPathComponent("status.json") }
    var settings: URL { root.appendingPathComponent("settings.json") }
    /// Lock-screen stills the agent sets as the system desktop picture.
    var frames: URL { root.appendingPathComponent("Frames", isDirectory: true) }
    /// The system desktop pictures in place before the agent replaced them.
    var originalDesktop: URL { root.appendingPathComponent("original-desktop.json") }
    /// The Aerial video and Desktop choices replaced to play the wallpaper on the lock screen.
    var aerialBackup: URL { root.appendingPathComponent("Aerial", isDirectory: true) }
    /// Which Aerial is replaced, and with what.
    var aerialState: URL { root.appendingPathComponent("aerial.json") }

    func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
    }
}
