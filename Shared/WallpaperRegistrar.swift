import Foundation
import ServiceManagement

enum RegistrationError: LocalizedError {
    case requiresApproval

    var errorDescription: String? {
        "Allow LiveWallpaper in System Settings › General › Login Items, then try again."
    }
}

/// The minimum wallpaper integration: make sure the playback agent is
/// registered with launchd and tell it to pick up the current config.
enum WallpaperRegistrar {
    static let agentPlistName = "com.hari.LiveWallpaper.Agent.plist"

    private static var service: SMAppService { SMAppService.agent(plistName: agentPlistName) }

    static var status: SMAppService.Status { service.status }

    static func register() throws {
        if service.status != .enabled {
            try service.register()
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            throw RegistrationError.requiresApproval
        }
        // A freshly registered agent reads config.json at launch; an already
        // running one needs to be told.
        DistributedNotificationCenter.default().postNotificationName(
            WallpaperNotifications.reload, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    static func unregister() throws {
        guard service.status != .notRegistered else { return }
        try service.unregister()
    }
}
