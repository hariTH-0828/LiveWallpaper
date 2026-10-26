import AppKit
import SwiftUI

@main
struct LiveWallpaperApp: App {
    @StateObject private var model = WallpaperModel()

    init() {
        // `--unregister` is used by tests and scripts: stop the agent and exit.
        if CommandLine.arguments.contains("--unregister") {
            try? WallpaperRegistrar.unregister()
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("LiveWallpaper") {
            ContentView(model: model)
                .task { await model.runLaunchArguments() }
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class WallpaperModel: ObservableObject {
    @Published var config: WallpaperConfig?
    @Published var errorMessage: String?
    @Published var isWorking = false
    @Published private var folderVideoCount: Int?

    private let store = WallpaperStore()

    init() {
        config = store.currentConfig
    }

    /// `--import <path>`: import and register without any UI interaction.
    func runLaunchArguments() async {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--import"), args.indices.contains(index + 1) else {
            startAgent()
            return
        }
        await importVideo(from: URL(fileURLWithPath: args[index + 1]))
    }

    /// The agent owns the menu bar item, so it runs whenever the app has been opened, with or
    /// without a wallpaper. Quit in the menu bar stops it; opening the app brings it back.
    private func startAgent() {
        guard WallpaperRegistrar.status != .enabled else { return }
        do {
            try WallpaperRegistrar.register()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importVideo(from url: URL) async {
        isWorking = true
        defer { isWorking = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            config = try await store.importVideo(from: url)
            folderVideoCount = nil
            try WallpaperRegistrar.register()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Plays the folder's .mp4 files in shuffled order, in place.
    func importFolder(from url: URL) async {
        isWorking = true
        defer { isWorking = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let result = try store.importFolder(from: url)
            config = result.config
            folderVideoCount = result.videoCount
            try WallpaperRegistrar.register()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var currentDescription: String {
        guard let config else { return "None" }
        guard let folder = config.folderURL else { return config.videoURL.lastPathComponent }
        let count = folderVideoCount ?? ((try? FolderScanner.videos(in: folder))?.count ?? 0)
        return "\(folder.lastPathComponent) — shuffling \(count) video\(count == 1 ? "" : "s")"
    }

    /// Clears the wallpaper but leaves the agent, and its menu bar item, running. The agent
    /// sees there is no config and puts the system wallpaper back.
    func stop() {
        store.clear()
        config = nil
        folderVideoCount = nil
        DistributedNotificationCenter.default().postNotificationName(
            WallpaperNotifications.reload, object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}
