import SwiftUI

struct ContentView: View {
    @ObservedObject var model: WallpaperModel
    @State private var isImporting = false
    /// One `.fileImporter` serves both buttons; SwiftUI only honours one per view.
    @State private var pickingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledContent("Current wallpaper") {
                Text(model.currentDescription)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Import Video…") {
                    pickingFolder = false
                    isImporting = true
                }
                .keyboardShortcut("o")
                Button("Choose Folder…") {
                    pickingFolder = true
                    isImporting = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .help("Shuffle the .mp4 videos in a folder")
                Button("Stop Wallpaper", role: .destructive) { model.stop() }
                    .disabled(model.config == nil)
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
            }

            Text("The video keeps playing after you quit this app. Use the menu bar item for speed, shuffle and power settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520)
        .disabled(model.isWorking)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: pickingFolder ? [.folder] : [.movie]) { result in
            guard case .success(let url) = result else { return }
            Task {
                if pickingFolder {
                    await model.importFolder(from: url)
                } else {
                    await model.importVideo(from: url)
                }
            }
        }
        .alert(
            "Couldn't set wallpaper",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
