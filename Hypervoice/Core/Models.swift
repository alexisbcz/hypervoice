import AppKit
import HuggingFace
import Observation

/// A model on disk: an engine, or Whisper.
enum ModelID: Hashable, Identifiable, Sendable {
    case engine(Engine)
    case whisper

    var id: String { repository }

    var name: String {
        switch self {
        case .engine(let engine): engine.name
        case .whisper: Whisper.name
        }
    }

    var summary: String {
        switch self {
        case .engine(let engine): engine.summary
        case .whisper: Whisper.summary
        }
    }

    var repository: String {
        switch self {
        case .engine(let engine): engine.repository
        case .whisper: Whisper.repository
        }
    }

    var downloadSize: Int64 {
        switch self {
        case .engine(let engine): engine.downloadSize
        case .whisper: Whisper.downloadSize
        }
    }

    static let all: [ModelID] = Engine.allCases.map(ModelID.engine) + [.whisper]
}

/// Which models are downloaded, and the progress of those downloading.
/// MLX Audio keeps each model in its own folder in the Hugging Face cache.
@Observable
final class ModelStore {
    static let shared = ModelStore()

    /// Bytes on disk for each downloaded model.
    private(set) var installed: [ModelID: Int64] = [:]
    /// Models downloading or loading, with the bytes so far.
    private(set) var downloading: [ModelID: Int64] = [:]
    private(set) var errors: [ModelID: String] = [:]

    @ObservationIgnored private var watcher: Timer?

    init() { refresh() }

    static func folder(of model: ModelID) -> URL {
        HubCache.default.cacheDirectory
            .appending(path: "mlx-audio", directoryHint: .isDirectory)
            .appending(path: model.repository.replacingOccurrences(of: "/", with: "_"), directoryHint: .isDirectory)
    }

    func isInstalled(_ model: ModelID) -> Bool { installed[model] != nil }
    func isInstalled(_ engine: Engine) -> Bool { isInstalled(.engine(engine)) }

    /// Fraction downloaded, from the folder's size against the expected size.
    func progress(_ model: ModelID) -> Double? {
        downloading[model].map { min(0.99, Double($0) / Double(model.downloadSize)) }
    }

    var totalSize: Int64 { installed.values.reduce(0, +) }

    func refresh() {
        var installed: [ModelID: Int64] = [:]
        for model in ModelID.all where downloading[model] == nil {
            let folder = Self.folder(of: model)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            guard files.contains(where: { $0.pathExtension == "safetensors" }) else { continue }
            installed[model] = Self.size(of: folder)
        }
        self.installed = installed
    }

    /// Downloads, then loads, so the model is ready the moment it's needed.
    func download(_ model: ModelID) {
        guard downloading[model] == nil else { return }
        errors[model] = nil
        downloading[model] = 0
        startWatching()
        Task {
            do {
                switch model {
                case .engine(let engine): try await Synth.shared.prepare(engine)
                case .whisper: try await Transcriber.shared.prepare()
                }
            } catch {
                errors[model] = error.localizedDescription
            }
            downloading[model] = nil
            refresh()
        }
    }

    /// Called by whatever loads a model, so the Models list shows a download it didn't start.
    func track<T>(_ model: ModelID, _ body: () async throws -> T) async rethrows -> T {
        let isNew = !isInstalled(model) && downloading[model] == nil
        if isNew {
            downloading[model] = 0
            startWatching()
        }
        defer {
            if isNew {
                downloading[model] = nil
                refresh()
            }
        }
        return try await body()
    }

    func delete(_ model: ModelID) {
        Task {
            switch model {
            case .engine(let engine):
                if await Synth.shared.loadedEngine == engine { await Synth.shared.unload() }
            case .whisper:
                await Transcriber.shared.unload()
            }
            try? FileManager.default.removeItem(at: Self.folder(of: model))
            refresh()
        }
    }

    func reveal(_ model: ModelID) {
        NSWorkspace.shared.activateFileViewerSelecting([Self.folder(of: model)])
    }

    private func startWatching() {
        guard watcher == nil else { return }
        watcher = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { ModelStore.shared.tick() }
        }
    }

    private func tick() {
        guard !downloading.isEmpty else {
            watcher?.invalidate()
            watcher = nil
            return
        }
        for model in downloading.keys {
            downloading[model] = Self.size(of: Self.folder(of: model))
        }
    }

    private static func size(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
