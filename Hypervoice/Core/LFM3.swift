import Darwin
import Foundation

/// LFM3 Audio, which MLX Audio can't run: llama.cpp's `llama-server` runs it in a child process on 127.0.0.1.
/// It speaks over the server's realtime WebSocket, which keeps the model loaded between sentences and sends
/// the audio as it's made, and transcribes through chat completions. llama.cpp and the weights download into
/// one folder the first time it's used.
actor LFM3 {
    static let shared = LFM3()
    static let sampleRate = 24_000

    /// The first llama.cpp release that runs LFM3; Homebrew's is older.
    static let build = "b11960"
    static let runtimeURL = URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/\(build)/llama-\(build)-bin-macos-arm64.tar.gz")!
    /// The 8-bit backbone, as the model card recommends, and the audio encoder and decoder.
    static let weights = ["LFM3-Audio-2B-Q8_0.gguf", "mmproj-LFM3-Audio-2B-Q8_0.gguf"]

    static let folder = URL.applicationSupportDirectory
        .appending(path: "Hypervoice", directoryHint: .isDirectory)
        .appending(path: "LFM3-Audio-2B-GGUF", directoryHint: .isDirectory)
    private static let runtime = folder.appending(path: "llama-\(build)", directoryHint: .isDirectory)
    private static let executable = runtime.appending(path: "llama-server")
    private static let log = folder.appending(path: "llama-server.log")

    nonisolated static var isInstalled: Bool {
        weights.allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
    }

    private var process: Process?
    private var port = 0
    /// The running server's pid, so quitting the app can stop it without waiting on the actor.
    nonisolated(unsafe) private static var pid: pid_t = 0

    // MARK: - Running

    /// Downloads what's missing, then starts the server and waits until the model has loaded.
    func start() async throws {
        if let process, process.isRunning { return }
        try await install()
        try Task.checkCancellation()
        // HYPERVOICE_LLAMA_PORT pins the port, for testing against a known one.
        port = ProcessInfo.processInfo.environment["HYPERVOICE_LLAMA_PORT"].flatMap(Int.init) ?? Self.freePort()
        FileManager.default.createFile(atPath: Self.log.path, contents: nil)
        let output = try FileHandle(forWritingTo: Self.log)
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = [
            "-m", Self.folder.appending(path: Self.weights[0]).path,
            "--mmproj", Self.folder.appending(path: Self.weights[1]).path,
            "--host", "127.0.0.1", "--port", String(port),
            // The model's 32K context, shared by two requests at a time: speech and a transcription.
            "-c", "32768", "-np", "2", "--no-webui", "--offline",
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        self.process = process
        Self.pid = process.processIdentifier

        let deadline = Date.now.addingTimeInterval(180)
        while Date.now < deadline {
            if !process.isRunning {
                self.process = nil
                throw LFM3Error("llama.cpp stopped while loading LFM3 Audio. \(Self.logTail())")
            }
            if let (_, response) = try? await URLSession.shared.data(from: endpoint("/health")),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        stop()
        throw LFM3Error("LFM3 Audio took too long to load. \(Self.logTail())")
    }

    func stop() {
        process?.terminate()
        process = nil
        Self.pid = 0
    }

    /// For quitting: a child process outlives its parent unless told to stop.
    nonisolated static func terminate() {
        if pid > 0 { kill(pid, SIGTERM) }
    }

    // MARK: - Speech

    /// One stretch of speech in a preset voice, as 24 kHz mono samples. Each call is a fresh session,
    /// so earlier sentences don't fill the context or colour the next.
    func speak(_ text: String, voice: String?) async throws -> [Float] {
        try await start()
        var request = URLRequest(url: endpoint("/v1/realtime", scheme: "ws"))
        request.timeoutInterval = 300
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        // About 12 audio tokens a second: this lets any sentence finish but stops one that never would.
        let limit = 200 + text.count * 3
        let events: [[String: Any]] = [
            ["type": "session.update", "session": [
                "type": "realtime", "instructions": LFM3Voices.instructions(voice),
                "output_modalities": ["audio"], "max_output_tokens": limit,
            ]],
            ["type": "conversation.item.create", "item": [
                "type": "message", "role": "user", "content": [["type": "input_text", "text": text]],
            ]],
            ["type": "response.create"],
        ]
        return try await withTaskCancellationHandler {
            for event in events {
                try await socket.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)))
            }
            var pcm = Data()
            while true {
                let message = try await socket.receive()
                let data: Data = switch message {
                case .string(let text): Data(text.utf8)
                case .data(let data): data
                @unknown default: Data()
                }
                guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "response.output_audio.delta":
                    if let delta = (event["delta"] as? String).flatMap({ Data(base64Encoded: $0) }) { pcm.append(delta) }
                case "response.done":
                    return Self.samples(pcm16: pcm)
                case "error":
                    let error = event["error"] as? [String: Any]
                    throw LFM3Error(error?["message"] as? String ?? "LFM3 Audio couldn't speak this.")
                default:
                    continue
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func samples(pcm16 data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
    }

    // MARK: - Transcription

    static let transcriptionRate = 16_000
    /// The model hears up to about this much at once; longer audio goes in pieces.
    private static let pieceSeconds = 30.0

    /// What's said in 16 kHz mono samples, using the model card's ASR system prompt.
    func transcribe(_ samples: [Float], source: URL, language: String? = nil) async throws -> Transcript {
        try await start()
        let instructions = LFM3Voices.asrInstructions(language)
        var segments: [Transcript.Segment] = []
        for piece in Self.pieces(of: samples) {
            try Task.checkCancellation()
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try WAV.write(Array(samples[piece]), sampleRate: Self.transcriptionRate, to: url)
            let body: [String: Any] = [
                "messages": [
                    ["role": "system", "content": instructions],
                    ["role": "user", "content": [["type": "input_audio", "input_audio": ["data": try Data(contentsOf: url).base64EncodedString(), "format": "wav"]]]],
                ],
                "temperature": 0, "max_tokens": 1024,
            ]
            var request = URLRequest(url: endpoint("/v1/chat/completions"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 300
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let choice = (json?["choices"] as? [[String: Any]])?.first,
                  let text = (choice["message"] as? [String: Any])?["content"] as? String
            else {
                let message = (json?["error"] as? [String: Any])?["message"] as? String
                throw LFM3Error(message ?? "LFM3 Audio couldn't transcribe this.")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let rate = Double(Self.transcriptionRate)
                segments.append(.init(start: Double(piece.lowerBound) / rate, end: Double(piece.upperBound) / rate, text: trimmed))
            }
        }
        return Transcript(source: source, text: segments.map(\.text).joined(separator: " "), segments: segments, language: language)
    }

    /// Stretches of at most `pieceSeconds`, each cut at the quietest moment of its last few seconds so words stay whole.
    private static func pieces(of samples: [Float]) -> [Range<Int>] {
        let length = Int(pieceSeconds) * transcriptionRate
        let window = transcriptionRate / 10
        var pieces: [Range<Int>] = []
        var start = 0
        while samples.count - start > length {
            var cut = start + length
            var quietest = Float.infinity
            for position in stride(from: start + length - 5 * transcriptionRate, to: start + length - window, by: window) {
                let loudness = samples[position..<position + window].reduce(0) { $0 + abs($1) }
                if loudness < quietest { quietest = loudness; cut = position + window / 2 }
            }
            pieces.append(start..<cut)
            start = cut
        }
        if start < samples.count { pieces.append(start..<samples.count) }
        return pieces
    }

    // MARK: - Installing

    /// llama.cpp from its GitHub release, then the weights from Hugging Face, into `folder`,
    /// where the Models list measures them as they arrive.
    private func install() async throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if !FileManager.default.isExecutableFile(atPath: Self.executable.path) {
            let archive = Self.folder.appending(path: Self.runtimeURL.lastPathComponent)
            try await Download.file(Self.runtimeURL, to: archive)
            defer { try? FileManager.default.removeItem(at: archive) }
            try Self.run("/usr/bin/tar", "-xzf", archive.path, "-C", Self.folder.path)
            // Downloaded binaries carry the quarantine flag, and Gatekeeper would stop each unsigned dylib.
            try? Self.run("/usr/bin/xattr", "-dr", "com.apple.quarantine", Self.runtime.path)
            guard FileManager.default.isExecutableFile(atPath: Self.executable.path) else {
                throw LFM3Error("The llama.cpp download didn't contain llama-server.")
            }
        }
        for file in Self.weights where !FileManager.default.fileExists(atPath: Self.folder.appending(path: file).path) {
            let url = URL(string: "https://huggingface.co/\(Engine.lfm3.repository)/resolve/main/\(file)")!
            try await Download.file(url, to: Self.folder.appending(path: file))
        }
    }

    private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LFM3Error("\(URL(fileURLWithPath: tool).lastPathComponent) failed while installing llama.cpp.")
        }
    }

    // MARK: - Helpers

    private func endpoint(_ path: String, scheme: String = "http") -> URL {
        URL(string: "\(scheme)://127.0.0.1:\(port)\(path)")!
    }

    /// A port nothing is listening on, from the system.
    private static func freePort() -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : 8771
    }

    /// The end of the server's log, which says why it stopped.
    private static func logTail() -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(3).joined(separator: " ")
    }
}

nonisolated struct LFM3Error: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A large file over HTTP, written straight into its folder as it arrives (so its size there is the progress)
/// and picked up where it stopped if a download is interrupted.
nonisolated enum Download {
    static func file(_ url: URL, to destination: URL) async throws {
        let partial = destination.appendingPathExtension("part")
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        let offset = try handle.seekToEnd()
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let writer = Writer(handle)
        let session = URLSession(configuration: .default, delegate: writer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                writer.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private final class Writer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let handle: FileHandle
        var continuation: CheckedContinuation<Void, Error>?
        private var failure: Error?
        /// The partial file already held everything: the server has nothing past its end.
        private var isComplete = false

        init(_ handle: FileHandle) { self.handle = handle }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 206: return .allow
            case 200:
                // The server ignored the range: start over.
                try? handle.truncate(atOffset: 0)
                return .allow
            case 416:
                isComplete = true
                return .cancel
            default:
                failure = LFM3Error("Downloading \(response.url?.lastPathComponent ?? "a file") failed (HTTP \(status)).")
                return .cancel
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do { try handle.write(contentsOf: data) } catch {
                failure = error
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle.close()
            if let failure = failure ?? (isComplete ? nil : error) {
                continuation?.resume(throwing: failure)
            } else {
                continuation?.resume()
            }
            continuation = nil
        }
    }
}
