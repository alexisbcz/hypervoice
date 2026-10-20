import SwiftUI

/// Everything you've generated, newest first. Drag a row out to use the audio anywhere.
struct HistoryView: View {
    @Environment(Studio.self) private var studio
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var selection = Set<Clip.ID>()
    @State private var search = ""

    var body: some View {
        let clips = search.isEmpty ? library.clips : library.clips.filter { "\($0.text) \($0.voiceName)".localizedStandardContains(search) }
        Group {
            if library.clips.isEmpty {
                EmptyState(title: "No Clips Yet", icon: "clock", message: "Everything you generate in Speech and Script is saved here.") {
                    Button("Go to Speech") { studio.section = .speech }
                }
            } else {
                Table(of: Clip.self, selection: $selection) {
                    TableColumn("") { clip in
                        Button {
                            player.toggle(clip)
                        } label: {
                            Image(systemName: player.isPlaying(clip.id.uuidString) ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(28)
                    TableColumn("Text") { clip in
                        Text(clip.text.replacingOccurrences(of: "\n", with: " ")).lineLimit(1)
                    }
                    .width(min: 160, ideal: 340)
                    TableColumn("Voice") { clip in Text(clip.voiceName).foregroundStyle(.secondary) }
                        .width(min: 80, ideal: 120)
                    TableColumn("Engine") { clip in Text(clip.engine?.name ?? "Several").foregroundStyle(.secondary) }
                        .width(min: 80, ideal: 130)
                    TableColumn("Length") { clip in Text(clip.duration.clock).monospacedDigit().foregroundStyle(.secondary) }
                        .width(56)
                    TableColumn("Created") { clip in
                        Text(clip.created, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                    }
                    .width(min: 90, ideal: 110)
                } rows: {
                    ForEach(clips) { clip in
                        TableRow(clip).draggable(library.url(of: clip))
                    }
                }
                .contextMenu(forSelectionType: Clip.ID.self) { ids in
                    let chosen = library.clips.filter { ids.contains($0.id) }
                    if let clip = chosen.first, chosen.count == 1 {
                        Button(player.isPlaying(clip.id.uuidString) ? "Pause" : "Play") { player.toggle(clip) }
                        Button("Edit in Speech") {
                            studio.draft = clip.text
                            if let voice = library.voice(named: clip.voiceName) { studio.voiceID = voice.id }
                            studio.section = .speech
                        }
                        Button("Copy Text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(clip.text, forType: .string)
                        }
                        Divider()
                    }
                    if !chosen.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(chosen.map(library.url(of:))) }
                        Button("Delete", role: .destructive) { delete(ids) }
                    }
                } primaryAction: { ids in
                    if let clip = library.clips.first(where: { ids.contains($0.id) }) { player.toggle(clip) }
                }
                .onDeleteCommand { delete(selection) }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search clips")
        .navigationTitle("History")
        .navigationSubtitle(library.clips.isEmpty ? "" : "\(library.clips.count) clip\(library.clips.count == 1 ? "" : "s") · \(library.clips.reduce(0) { $0 + $1.duration }.clock)")
        .toolbar {
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.open(Library.clipsFolder) }
        }
    }

    private func delete(_ ids: Set<Clip.ID>) {
        if let playing = player.playing, ids.contains(where: { $0.uuidString == playing }) { player.stop() }
        library.delete(ids)
        selection.subtract(ids)
    }
}
