import SwiftUI

/// Why playback is held back. Only the power rules ever pause the wallpaper.
enum PauseReason: String {
    case lowPowerMode
    case onBattery

    var message: String {
        switch self {
        case .lowPowerMode: return "Paused: Low Power Mode is on"
        case .onBattery: return "Paused: running on battery"
        }
    }
}

@MainActor
final class MenuBarModel: ObservableObject {
    @Published var settings = PlaybackSettings()
    @Published var pauseReason: PauseReason?
    @Published var currentDescription = "None"
    @Published var isFolderMode = false

    var onSettingsChanged: ((PlaybackSettings) -> Void)?
    var onChooseVideo: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onSyncFolder: (() -> Void)?
    var onQuit: (() -> Void)?

    func binding<Value>(_ keyPath: WritableKeyPath<PlaybackSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in
                self.settings[keyPath: keyPath] = value
                self.onSettingsChanged?(self.settings)
            }
        )
    }
}

struct MenuBarView: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LiveWallpaper").font(.headline)
                Text(model.currentDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Run", selection: model.binding(\.runMode)) {
                    Text("Every time").tag(RunMode.always)
                    Text("On power adapter").tag(RunMode.onPowerAdapter)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let reason = model.pauseReason {
                    Label(reason.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Always pauses in Low Power Mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Speed", selection: model.binding(\.speed)) {
                ForEach(PlaybackSettings.speeds, id: \.self) { speed in
                    Text(speed.formatted() + "×").tag(speed)
                }
            }
            .pickerStyle(.menu)

            Toggle("Shuffle", isOn: model.binding(\.shuffle))
                .toggleStyle(.switch)
                .disabled(!model.isFolderMode)
                .help(model.isFolderMode ? "Play the folder's videos in random order" : "Only applies to a folder")

            Divider()

            HStack {
                Button("Choose Wallpaper…") { model.onChooseVideo?() }
                Button("Choose Folder…") { model.onChooseFolder?() }
            }

            Button {
                model.onSyncFolder?()
            } label: {
                Label("Sync Folder", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!model.isFolderMode)
            .help(model.isFolderMode ? "Pick up videos added to or removed from the folder" : "Only applies to a folder")

            Divider()

            Button(role: .destructive) {
                model.onQuit?()
            } label: {
                Label("Quit LiveWallpaper", systemImage: "power")
            }
            .help("Stop the live wallpaper, restore the system wallpaper and stop the agent")
        }
        .padding(16)
        .frame(width: 300)
    }
}
