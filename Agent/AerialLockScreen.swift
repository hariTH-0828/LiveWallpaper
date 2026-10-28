import AppKit

/// Plays the wallpaper on the lock screen. macOS draws the lock screen itself and only animates
/// Apple's Aerials there, so the main screen's video is copied over one Aerial's video file and
/// that Aerial is selected as every Desktop's wallpaper. This needs the per-user Aerials folder
/// of macOS 26; elsewhere `init` fails and the controller falls back to `SystemWallpaper`'s stills.
/// The Aerial's own file and the Desktop choices from before the first change are saved and put
/// back by `restore()`.
@MainActor
final class AerialLockScreen {
    private struct State: Codable {
        var assetID: String
        /// The video last copied over the Aerial.
        var installedSource: String?
        /// The Aerial file existed before, and was moved into `aerialBackup`.
        var hadOriginalFile = false
        /// The Desktop choices were looked at once; `desktop-backup.plist` exists if they were worth keeping.
        var desktopBackupTaken = false
    }

    private static let provider = "com.apple.wallpaper.choice.aerials"
    /// "Tahoe Day", the Aerial already tried with a copied-in H.264 clip.
    private static let defaultAssetID = "4C108785-A7BA-422E-9C79-B0129F1D5550"
    private static let restartInterval: TimeInterval = 5

    private let paths: WallpaperPaths
    private let videosDir: URL
    private let indexPlist: URL
    private var state: State
    /// Bumped per install, so a slow copy never replaces a newer one.
    private var generation = 0
    private var restartPending = false
    private var lastRestart = Date.distantPast

    init?(paths: WallpaperPaths) {
        let wallpaper = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.apple.wallpaper", isDirectory: true)
        let aerials = wallpaper.appendingPathComponent("aerials", isDirectory: true)
        let manifest = aerials.appendingPathComponent("manifest/entries.json")
        videosDir = aerials.appendingPathComponent("videos", isDirectory: true)
        indexPlist = wallpaper.appendingPathComponent("Store/Index.plist")
        self.paths = paths

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: videosDir.path), fileManager.fileExists(atPath: indexPlist.path) else {
            return nil
        }
        if let saved = JSONFile.read(State.self, from: paths.aerialState) {
            state = saved
        } else if let assetID = Self.pickAsset(manifest: manifest, videos: videosDir) {
            state = State(assetID: assetID)
        } else {
            return nil
        }
    }

    private var aerialFile: URL { videosDir.appendingPathComponent("\(state.assetID).mov") }
    private var backupFile: URL { paths.aerialBackup.appendingPathComponent("\(state.assetID).mov") }
    private var desktopBackup: URL { paths.aerialBackup.appendingPathComponent("desktop-backup.plist") }
    private var isInstalled: Bool { state.installedSource != nil }

    // MARK: - Install

    /// Copies `video` over the Aerial and makes sure that Aerial is the selected wallpaper.
    func install(_ video: URL) {
        if state.installedSource == video.path, Self.fingerprint(aerialFile) == Self.fingerprint(video) {
            ensureSelected()
            return
        }
        generation += 1
        let token = generation
        let staging = paths.aerialBackup

        Task {
            // Copying is an instant clone on the same APFS volume, but a folder on another
            // disk is a real copy, so keep it off the main thread.
            let staged = await Task.detached { try? Self.stage(video, in: staging) }.value
            guard let staged else { return }
            guard token == generation else {
                try? FileManager.default.removeItem(at: staged)
                return
            }
            do {
                try backUpOriginalIfNeeded()
                // rename(2) swaps the file in one step, so the lock screen never sees half a video.
                guard rename(staged.path, aerialFile.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            } catch {
                try? FileManager.default.removeItem(at: staged)
                return
            }
            state.installedSource = video.path
            saveState()
            ensureSelected()
            // The running WallpaperAgent may still hold the old file open.
            scheduleWallpaperAgentRestart()
        }
    }

    /// Puts our Aerial back as the selected wallpaper if something else was chosen meanwhile.
    func reapplySelection() {
        guard isInstalled else { return }
        ensureSelected()
    }

    private nonisolated static func stage(_ video: URL, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(".incoming-\(UUID().uuidString).mov")
        try FileManager.default.copyItem(at: video, to: staged)
        return staged
    }

    private func backUpOriginalIfNeeded() throws {
        guard !isInstalled, !FileManager.default.fileExists(atPath: backupFile.path) else { return }
        if FileManager.default.fileExists(atPath: aerialFile.path) {
            try FileManager.default.moveItem(at: aerialFile, to: backupFile)
            state.hadOriginalFile = true
        }
    }

    // MARK: - Selection

    /// Makes every Desktop entry in the wallpaper store choose our Aerial, then restarts
    /// WallpaperAgent so it reads the change. Screen saver (Idle) entries are left alone.
    /// When `verify` is set, it looks again once the agent has restarted, in case the
    /// agent wrote its own state over ours on the way out.
    private func ensureSelected(verify: Bool = true) {
        guard let (root, format) = readIndex() else { return }
        let choice = Self.choice(for: state.assetID)
        var originals: [String: Any] = [:]
        let updated = Self.mapDesktopContents(root, path: "") { path, content in
            guard !Self.isChoice(content, assetID: state.assetID) else { return content }
            originals[path] = content
            var content = content
            content["Choices"] = [choice]
            content["Shuffle"] = "$null"
            return content
        }
        guard !originals.isEmpty else { return }

        saveDesktopBackupIfNeeded(originals)
        guard writeIndex(updated, format: format) else { return }
        scheduleWallpaperAgentRestart()
        if verify {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartInterval + 3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isInstalled else { return }
                    self.ensureSelected(verify: false)
                }
            }
        }
    }

    /// The first time only. Skipped when the choices are leftovers of ours, a still frame or
    /// this Aerial, which shouldn't come back as "the original".
    private func saveDesktopBackupIfNeeded(_ originals: [String: Any]) {
        guard !state.desktopBackupTaken else { return }
        state.desktopBackupTaken = true
        saveState()
        let ours = originals.values.contains { content in
            Self.configurations(of: content).contains {
                $0.contains("LiveWallpaper/Frames") || $0.contains(state.assetID)
            }
        }
        guard !ours,
              let data = try? PropertyListSerialization.data(fromPropertyList: originals, format: .binary, options: 0)
        else { return }
        try? FileManager.default.createDirectory(at: paths.aerialBackup, withIntermediateDirectories: true)
        try? data.write(to: desktopBackup, options: .atomic)
    }

    // MARK: - Restore

    /// Puts the Aerial's own file and the earlier Desktop choices back. Used by Quit, on
    /// SIGTERM and when the wallpaper is cleared.
    func restore() {
        generation += 1
        guard isInstalled || FileManager.default.fileExists(atPath: paths.aerialState.path) else { return }

        if FileManager.default.fileExists(atPath: backupFile.path) {
            _ = rename(backupFile.path, aerialFile.path)
        } else if !state.hadOriginalFile {
            // Nothing was there before: let macOS download Apple's video again.
            try? FileManager.default.removeItem(at: aerialFile)
        }

        if let data = try? Data(contentsOf: desktopBackup),
           let snapshot = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let (root, format) = readIndex() {
            let restored = Self.mapDesktopContents(root, path: "") { path, content in
                snapshot[path] as? [String: Any] ?? content
            }
            _ = writeIndex(restored, format: format)
        }
        restartWallpaperAgent()

        try? FileManager.default.removeItem(at: paths.aerialState)
        try? FileManager.default.removeItem(at: paths.aerialBackup)
        state = State(assetID: state.assetID)
    }

    // MARK: - WallpaperAgent

    /// At most one restart every `restartInterval`; a burst of changes shares one.
    private func scheduleWallpaperAgentRestart() {
        guard !restartPending else { return }
        restartPending = true
        let wait = max(0, Self.restartInterval - Date().timeIntervalSince(lastRestart))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restartPending = false
                self.restartWallpaperAgent()
            }
        }
    }

    /// launchd starts WallpaperAgent again on demand, and it reads the store afresh.
    private func restartWallpaperAgent() {
        lastRestart = Date()
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["WallpaperAgent"]
        killall.standardError = FileHandle.nullDevice
        try? killall.run()
        killall.waitUntilExit()
    }

    // MARK: - Helpers

    private func saveState() {
        try? paths.ensureDirectories()
        try? JSONFile.write(state, to: paths.aerialState)
    }

    private func readIndex() -> ([String: Any], PropertyListSerialization.PropertyListFormat)? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let data = try? Data(contentsOf: indexPlist),
              let root = try? PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any]
        else { return nil }
        return (root, format)
    }

    private func writeIndex(_ root: Any, format: PropertyListSerialization.PropertyListFormat) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0) else {
            return false
        }
        return (try? data.write(to: indexPlist, options: .atomic)) != nil
    }

    /// Rebuilds the store with every Desktop entry's `Content` replaced by `transform`, which
    /// gets the entry's key path too. `LastSet` is bumped where the content changed.
    private static func mapDesktopContents(
        _ value: Any, path: String, _ transform: (String, [String: Any]) -> [String: Any]
    ) -> Any {
        if let array = value as? [Any] {
            return array.enumerated().map { mapDesktopContents($1, path: "\(path)[\($0)]", transform) }
        }
        guard var dict = value as? [String: Any] else { return value }
        for (key, child) in dict {
            let childPath = "\(path)/\(key)"
            if key == "Desktop", var desktop = child as? [String: Any], let content = desktop["Content"] as? [String: Any] {
                let updated = transform(childPath, content)
                if !NSDictionary(dictionary: updated).isEqual(to: content) {
                    desktop["Content"] = updated
                    desktop["LastSet"] = Date()
                }
                dict[key] = desktop
            } else {
                dict[key] = mapDesktopContents(child, path: childPath, transform)
            }
        }
        return dict
    }

    private static func choice(for assetID: String) -> [String: Any] {
        let configuration = (try? PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID], format: .binary, options: 0
        )) ?? Data()
        return ["Configuration": configuration, "Files": [Any](), "Provider": provider]
    }

    private static func isChoice(_ content: [String: Any], assetID: String) -> Bool {
        guard let choices = content["Choices"] as? [[String: Any]], choices.count == 1,
              choices[0]["Provider"] as? String == provider,
              let data = choices[0]["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return configuration["assetID"] as? String == assetID
    }

    /// Each choice's decoded configuration, as text to search.
    private static func configurations(of content: Any) -> [String] {
        let choices = (content as? [String: Any])?["Choices"] as? [[String: Any]] ?? []
        return choices.compactMap { choice in
            guard let data = choice["Configuration"] as? Data,
                  let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil)
            else { return nil }
            return String(describing: configuration)
        }
    }

    /// The default Aerial if the manifest lists it, otherwise the first one already downloaded.
    private static func pickAsset(manifest: URL, videos: URL) -> String? {
        struct Manifest: Decodable {
            struct Asset: Decodable { var id: String }
            var assets: [Asset]
        }
        guard let ids = JSONFile.read(Manifest.self, from: manifest)?.assets.map(\.id) else { return nil }
        if ids.contains(defaultAssetID) { return defaultAssetID }
        return ids.first { FileManager.default.fileExists(atPath: videos.appendingPathComponent("\($0).mov").path) }
    }

    /// Size and modification date; a copy keeps both, so a match means the file is still ours.
    private nonisolated static func fingerprint(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return "\(size)-\(modified.timeIntervalSince1970)"
    }
}
