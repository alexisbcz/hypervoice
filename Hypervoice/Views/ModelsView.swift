import SwiftUI

/// Every model, what it's for, and whether it's on this Mac.
struct ModelsView: View {
    @Environment(ModelStore.self) private var models

    var body: some View {
        List {
            SwiftUI.Section {
                ForEach(Engine.allCases) { ModelRow(model: .engine($0), capabilities: Self.capabilities(of: $0)) }
            } header: {
                Text("Speech")
            }
            SwiftUI.Section {
                ModelRow(model: .whisper, capabilities: ["Transcription"])
            } header: {
                Text("Transcription")
            } footer: {
                Text("Models run entirely on this Mac through MLX. Each downloads from Hugging Face the first time you use it, then works offline. \(models.totalSize > 0 ? "Using \(models.totalSize.bytes)." : "")")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .navigationTitle("Models")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { models.refresh() }
        }
        .onAppear { models.refresh() }
    }

    static func capabilities(of engine: Engine) -> [String] {
        var tags: [String] = []
        if engine.clones { tags.append("Cloning") }
        if engine.designs { tags.append("Voice design") }
        if !engine.presets.isEmpty { tags.append("\(engine.presets.count) voice\(engine.presets.count == 1 ? "" : "s")") }
        if engine.takesDirection { tags.append("Direction") }
        return tags
    }
}

private struct ModelRow: View {
    @Environment(ModelStore.self) private var models
    let model: ModelID
    let capabilities: [String]

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: models.isInstalled(model) ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(models.isInstalled(model) ? Color.green : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).font(.headline)
                    ForEach(capabilities, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                Text(model.summary).foregroundStyle(.secondary)
                Text(model.repository).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                if let error = models.errors[model] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if let progress = models.progress(model) {
                VStack(alignment: .trailing, spacing: 4) {
                    if progress > 0.01 {
                        ProgressView(value: progress).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("\(models.downloading[model]?.bytes ?? "") of \(model.downloadSize.bytes)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            } else if let size = models.installed[model] {
                Text(size.bytes).foregroundStyle(.secondary).monospacedDigit()
                Menu {
                    Button("Show in Finder") { models.reveal(model) }
                    Divider()
                    Button("Delete", role: .destructive) { models.delete(model) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Text(model.downloadSize.bytes).foregroundStyle(.secondary).monospacedDigit()
                Button("Download") { models.download(model) }
            }
        }
        .padding(.vertical, 6)
    }
}
