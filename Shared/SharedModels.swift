import AVFoundation
import Foundation

/// The registered wallpaper. Written by the app, read by the agent.
struct WallpaperConfig: Codable, Equatable {
    /// The imported copy of a single video; empty when `folderPath` is set.
    var videoPath: String
    var importedAt: Date
    /// A folder whose .mp4 files are shuffled and played in place.
    var folderPath: String? = nil

    var videoURL: URL { URL(fileURLWithPath: videoPath) }
    var folderURL: URL? { folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
}

/// Playback heartbeat. Written by the agent, read by the app and tests.
struct AgentStatus: Codable, Equatable {
    var pid: Int32
    /// The file currently playing (in folder mode, the current shuffle pick).
    var videoPath: String?
    var currentTime: Double
    var rate: Float
    var windowCount: Int
    var updatedAt: Date
    var folderPath: String? = nil
    var lastError: String? = nil
    /// One entry per display; the top-level fields above mirror the main display.
    var screens: [ScreenStatus]? = nil
    /// Set while playback is held back by the power rules.
    var pauseReason: String? = nil
}

struct ScreenStatus: Codable, Equatable {
    var displayID: UInt32
    var videoPath: String?
    var currentTime: Double
    var rate: Float
}

/// When the agent is allowed to play. Low Power Mode always pauses it.
enum RunMode: String, Codable, CaseIterable {
    case always
    case onPowerAdapter
}

/// Menu bar choices. Written and read by the agent.
struct PlaybackSettings: Codable, Equatable {
    static let speeds: [Float] = [0.5, 0.75, 1]

    /// A saved speed that is no longer offered (e.g. 0.25×) becomes the nearest one that is.
    var normalized: PlaybackSettings {
        var settings = self
        settings.speed = Self.speeds.min { abs($0 - speed) < abs($1 - speed) } ?? 1
        return settings
    }

    var runMode: RunMode = .always
    var speed: Float = 1
    var shuffle: Bool = true
}

/// Finds the videos a shuffle folder contributes. Only the top level is searched.
enum FolderScanner {
    static let allowedExtensions: Set<String> = ["mp4"]

    static func videos(in folder: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { url in
                allowedExtensions.contains(url.pathExtension.lowercased())
                    && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// `videos(in:)` without the ones over `VideoLimits.maxDuration`, in the same order.
    static func allowedVideos(in folder: URL) async throws -> [URL] {
        let videos = try videos(in: folder)
        let allowed = await withTaskGroup(of: (URL, Bool).self) { group in
            for url in videos {
                group.addTask { (url, await VideoDurations.shared.isAllowed(url)) }
            }
            var allowed = Set<URL>()
            for await (url, isAllowed) in group where isAllowed {
                allowed.insert(url)
            }
            return allowed
        }
        return videos.filter(allowed.contains)
    }

    /// Videos that can play and ones known to be too long, for display. Lengths come from
    /// the cache, so videos not measured yet count as playable.
    static func counts(in folder: URL) -> (playable: Int, tooLong: Int) {
        let videos = (try? videos(in: folder)) ?? []
        let tooLong = videos.filter { VideoDurations.shared.cachedIsTooLong($0) == true }.count
        return (videos.count - tooLong, tooLong)
    }
}

/// Videos longer than this never play, on the desktop or on the lock screen.
enum VideoLimits {
    static let maxDuration: TimeInterval = 60
}

/// Video lengths, cached by path and modification date so folder rescans stay cheap.
final class VideoDurations: @unchecked Sendable {
    static let shared = VideoDurations()

    private struct Key: Hashable {
        var path: String
        var modified: Date?
    }

    private let lock = NSLock()
    private var cache: [Key: Double] = [:]

    func duration(of url: URL) async -> Double? {
        let key = Self.key(for: url)
        if let cached = lock.withLock({ cache[key] }) { return cached }
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return nil }
        let seconds = CMTimeGetSeconds(time)
        lock.withLock { cache[key] = seconds }
        return seconds
    }

    /// Files whose length can't be read pass; playback's own failure handling skips them.
    func isAllowed(_ url: URL) async -> Bool {
        guard let seconds = await duration(of: url) else { return true }
        return seconds <= VideoLimits.maxDuration
    }

    /// Nil when the video hasn't been measured yet.
    func cachedIsTooLong(_ url: URL) -> Bool? {
        let key = Self.key(for: url)
        return lock.withLock { cache[key] }.map { $0 > VideoLimits.maxDuration }
    }

    private static func key(for url: URL) -> Key {
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return Key(path: url.standardizedFileURL.path, modified: modified)
    }
}

enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

enum WallpaperNotifications {
    /// Posted on DistributedNotificationCenter when config.json changes.
    static let reload = Notification.Name("com.hari.LiveWallpaper.reload")
}
