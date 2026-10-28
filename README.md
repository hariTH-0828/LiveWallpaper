# LiveWallpaper

A macOS app that plays a video as your desktop wallpaper. It can loop one video, or shuffle all the `.mp4` files in a folder. The video plays on every display, behind your desktop icons, and keeps playing after you quit the app.

## Features

- **One video or a whole folder.** Import a single movie and it loops on every screen. Choose a folder instead and its `.mp4` files play one after another, shuffled or in name order. When there are several displays, each screen tries to show a different video.
- **Keeps playing after you quit the app.** Playback runs in a separate background agent that macOS starts at login, so closing the app doesn't stop the wallpaper.
- **Menu bar controls.** Change the speed (0.5×, 0.75×, 1×), turn shuffle on or off, rescan the folder, pick a new wallpaper or quit, all from the menu bar.
- **Smooth slow motion.** Below 1×, frames are blended together on every display refresh using Metal and Core Image, so slowed-down video doesn't stutter.
- **Power-aware.** Playback always pauses in Low Power Mode. You can also set it to play only while the Mac is plugged in. Speed changes ease in and out instead of jumping.
- **Live lock screen.** macOS draws the lock screen itself and only animates Apple's Aerials there. On macOS 26 the agent copies the main screen's current video over one Aerial (Tahoe Day) in `~/Library/Application Support/com.apple.wallpaper/aerials/videos/` and selects that Aerial as the Desktop wallpaper, so the video plays behind the clock and password field. No admin password is needed. In folder mode the lock screen follows the main screen's video. It plays at 1×, with the same video on every display. On older macOS the lock screen gets a still frame from each screen's video instead. Stopping or quitting puts back Apple's file and your earlier wallpaper.
- **Videos up to 1 minute.** Longer videos are refused on import. In a folder they're skipped, and the menu bar shows how many. They never play, on the desktop or on the lock screen.
- **Recovers on its own.** Playback restarts after sleep, unlocking, Space switches and connecting or disconnecting displays. Videos that fail or freeze are skipped automatically.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later
- An Apple Development signing identity. The background agent is registered with `SMAppService`, which refuses ad-hoc signed apps.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (optional), to regenerate the Xcode project from `project.yml`

## Getting started

1. Clone the repo and open `LiveWallpaper.xcodeproj`. If you change `project.yml`, regenerate the project first with `xcodegen generate`.
2. In the build settings, set `DEVELOPMENT_TEAM` to your own team ID. You can change it in `project.yml` or in Xcode.
3. Build and run the **LiveWallpaper** scheme.
4. Click **Import Video…** (⌘O) or **Choose Folder…** (⇧⌘O).
5. The first time, macOS may ask you to allow the agent in **System Settings › General › Login Items**. Allow it, then import again.

To stop the wallpaper, click **Stop Wallpaper** in the app. Choosing **Quit LiveWallpaper** in the menu bar also stops the background agent and restores your system wallpaper.

## How it works

The project has two processes. They share state through JSON files in `~/Library/Application Support/LiveWallpaper/`.

```
LiveWallpaper.app ──writes config.json──▶ LiveWallpaperAgent (launchd agent)
        │            + "reload" notification     │
        └── registers the agent via SMAppService ─┘
                                                 ├─ one ScreenPlayer per display
                                                 ├─ menu bar popover
                                                 └─ writes status.json (heartbeat)
```

| Target | What it does |
| --- | --- |
| `LiveWallpaper` (`App/`) | The SwiftUI window where you choose a wallpaper. It checks and copies imported videos, writes `config.json`, registers the agent and tells it to reload. |
| `LiveWallpaperAgent` (`Agent/`) | A background agent with no Dock icon, embedded in the app and started by launchd. It draws a borderless window behind the desktop icons on every screen and plays the video there with `AVQueuePlayer`. It also owns the menu bar item. |
| `Shared/` | Code used by both: the data models, file paths, the import logic (`WallpaperStore`) and agent registration (`WallpaperRegistrar`). |
| `LiveWallpaperTests` (`Tests/`) | Unit tests for the store, plus an end-to-end test that imports a video, quits the app and checks that the agent is still playing. |

### Files in `~/Library/Application Support/LiveWallpaper/`

| Path | Written by | Contents |
| --- | --- | --- |
| `config.json` | app (or agent menu) | The current wallpaper: an imported video path or a folder path |
| `Videos/` | app | Copies of imported single videos. A folder's videos are played where they are and never copied. |
| `settings.json` | agent | Menu bar settings: when to play, speed and shuffle |
| `status.json` | agent | Heartbeat updated every 0.5 s: what each screen is playing, the playback position, errors and any pause reason |
| `Frames/`, `original-desktop.json` | agent | The lock-screen stills, and the system wallpapers to restore afterwards (before macOS 26) |
| `Aerial/`, `aerial.json` | agent | The replaced Aerial's original video and Desktop choices, and which Aerial holds which video (macOS 26) |

### Command-line flags

The app takes two flags, used by the tests and handy for scripts:

```sh
LiveWallpaper.app/Contents/MacOS/LiveWallpaper --import /path/to/video.mp4   # import a video and register it without any UI
LiveWallpaper.app/Contents/MacOS/LiveWallpaper --unregister                  # stop and unregister the agent, then exit
```

## Running tests

Run the tests from the **LiveWallpaper** scheme with Product › Test (⌘U), or from the command line:

```sh
xcodebuild test -project LiveWallpaper.xcodeproj -scheme LiveWallpaper
```

The end-to-end test skips itself if a wallpaper is already set, so stop the current wallpaper before running it.
