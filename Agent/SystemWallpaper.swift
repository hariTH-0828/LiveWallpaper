import AppKit
import AVFoundation

/// The lock screen only ever shows the system desktop picture, so each screen's picture is set
/// to a still from the video it is playing. The pictures that were there before are saved
/// once and put back by `restore()`.
@MainActor
final class SystemWallpaper {
    private struct Original: Codable {
        var url: URL
        var options: [String: Data]
    }

    private let paths: WallpaperPaths
    /// Bumped per screen so a late frame grab never overwrites a newer one.
    private var generation: [CGDirectDisplayID: Int] = [:]

    init(paths: WallpaperPaths) {
        self.paths = paths
    }

    func setStill(from video: URL, on screen: NSScreen) {
        guard let displayID = screen.displayID else { return }
        let token = (generation[displayID] ?? 0) + 1
        generation[displayID] = token
        let size = screen.frame.size.applying(.init(scaleX: screen.backingScaleFactor, y: screen.backingScaleFactor))

        Task {
            guard let image = await Self.frame(of: video, maxSize: size),
                  generation[displayID] == token,
                  let target = NSScreen.screens.first(where: { $0.displayID == displayID })
            else { return }
            saveOriginalIfNeeded(for: target, displayID: displayID)

            // A new name every time: the system caches desktop pictures by URL.
            let url = paths.frames.appendingPathComponent("\(displayID)-\(UUID().uuidString).heic")
            do {
                try paths.ensureDirectories()
                try Self.write(image, to: url)
                try NSWorkspace.shared.setDesktopImageURL(url, for: target, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true,
                ])
            } catch {
                try? FileManager.default.removeItem(at: url)
                return
            }
            removeFrames(of: displayID, except: url)
        }
    }

    /// Puts back the desktop pictures saved before the first still was set.
    func restore() {
        generation.removeAll()
        if let originals = JSONFile.read([String: Original].self, from: paths.originalDesktop) {
            for screen in NSScreen.screens {
                guard let id = screen.displayID, let original = originals[String(id)] else { continue }
                try? NSWorkspace.shared.setDesktopImageURL(original.url, for: screen, options: Self.decode(original.options))
            }
        }
        try? FileManager.default.removeItem(at: paths.originalDesktop)
        try? FileManager.default.removeItem(at: paths.frames)
    }

    // MARK: - Helpers

    private func saveOriginalIfNeeded(for screen: NSScreen, displayID: CGDirectDisplayID) {
        var originals = JSONFile.read([String: Original].self, from: paths.originalDesktop) ?? [:]
        guard originals[String(displayID)] == nil,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              // Never record one of our own stills as the original, e.g. after a crash.
              url.deletingLastPathComponent().standardizedFileURL.path != paths.frames.standardizedFileURL.path
        else { return }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        originals[String(displayID)] = Original(url: url, options: Self.encode(options))
        try? JSONFile.write(originals, to: paths.originalDesktop)
    }

    private func removeFrames(of displayID: CGDirectDisplayID, except keep: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.frames, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("\(displayID)-") && file != keep {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func frame(of video: URL, maxSize: CGSize) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Desktop image options are plist values; store them archived so any of them round-trip.
    private static func encode(_ options: [NSWorkspace.DesktopImageOptionKey: Any]) -> [String: Data] {
        options.reduce(into: [:]) { result, entry in
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: entry.value, requiringSecureCoding: false) {
                result[entry.key.rawValue] = data
            }
        }
    }

    private static func decode(_ options: [String: Data]) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        options.reduce(into: [:]) { result, entry in
            let classes = [NSNumber.self, NSColor.self, NSString.self]
            if let value = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: entry.value) {
                result[NSWorkspace.DesktopImageOptionKey(rawValue: entry.key)] = value
            }
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
