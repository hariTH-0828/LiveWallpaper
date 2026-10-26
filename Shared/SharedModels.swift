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
