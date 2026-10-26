import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum ImportError: Error, Equatable, LocalizedError {
    case notAMovie
    case unplayable
    case copyFailed(String)
    case notAFolder
    case noVideosInFolder

    var errorDescription: String? {
        switch self {
        case .notAMovie: return "The selected file is not a movie."
        case .unplayable: return "The selected movie has no playable video track."
        case .copyFailed(let reason): return "Couldn't copy the movie: \(reason)"
        case .notAFolder: return "The selection is not a folder."
        case .noVideosInFolder: return "The folder has no .mp4 videos."
        }
    }
}

/// Owns the imported video and the config.json that registers it.
struct WallpaperStore {
    var paths: WallpaperPaths = .default

    var currentConfig: WallpaperConfig? {
        JSONFile.read(WallpaperConfig.self, from: paths.config)
    }

    /// Validates `url` as a playable movie, copies it into the shared Videos
    /// folder, records it in config.json and removes the previously imported copy.
    func importVideo(from url: URL) async throws -> WallpaperConfig {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type, type.conforms(to: .movie) else { throw ImportError.notAMovie }

        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard playable, !videoTracks.isEmpty else { throw ImportError.unplayable }

        let previous = currentConfig
        let destination = paths.videos
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.lowercased())
        do {
            try paths.ensureDirectories()
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }

        let config = WallpaperConfig(videoPath: destination.path, importedAt: Date())
        try JSONFile.write(config, to: paths.config)

        if let previous, previous.videoPath != config.videoPath {
            removeImportedCopy(of: previous)
        }
        return config
    }

    /// Registers a folder whose .mp4 files the agent shuffles through, played in place.
    /// Returns the config and the number of videos found now.
    func importFolder(from url: URL) throws -> (config: WallpaperConfig, videoCount: Int) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDirectory else { throw ImportError.notAFolder }
        let videos = (try? FolderScanner.videos(in: url)) ?? []
        guard !videos.isEmpty else { throw ImportError.noVideosInFolder }

        let previous = currentConfig
        try paths.ensureDirectories()
        let config = WallpaperConfig(videoPath: "", importedAt: Date(), folderPath: url.path)
        try JSONFile.write(config, to: paths.config)

        if let previous { removeImportedCopy(of: previous) }
        return (config, videos.count)
    }

    /// Forgets the registered wallpaper and deletes the imported copy, if any.
    func clear() {
        if let config = currentConfig { removeImportedCopy(of: config) }
        try? FileManager.default.removeItem(at: paths.config)
    }

    /// Deletes a config's video only if it is a copy this store made. Folder videos are the
    /// user's own files and are never touched.
    private func removeImportedCopy(of config: WallpaperConfig) {
        guard config.folderPath == nil, !config.videoPath.isEmpty,
              config.videoURL.deletingLastPathComponent().standardizedFileURL == paths.videos.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: config.videoURL)
    }
}
