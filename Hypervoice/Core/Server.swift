import Foundation
import Network
import Observation

/// A local HTTP API in the shape of OpenAI's audio endpoints, so existing clients and agents can speak
/// in your voices and transcribe audio. It listens on 127.0.0.1 only.
///
///     curl localhost:8770/v1/audio/speech -d '{"input": "Hello", "voice": "Ryan"}' -o hello.wav
///     curl localhost:8770/v1/audio/transcriptions -F file=@hello.wav
@Observable
final class Server {
    static let shared = Server()
    static let defaultPort = 8770

    private(set) var isRunning = false
    private(set) var port = defaultPort
    var error: String?

    @ObservationIgnored private var listener: NWListener?

    func setEnabled(_ enabled: Bool, port: Int) {
        stop()
        if enabled { start(port: port) }
    }

    private func start(port: Int) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { connection in
                MainActor.assumeIsolated { Server.shared.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: Server.shared.isRunning = true
                    case .failed(let error):
                        Server.shared.error = error.localizedDescription
                        Server.shared.isRunning = false
                    case .cancelled: Server.shared.isRunning = false
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            self.port = port
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            MainActor.assumeIsolated {
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = Request(buffer) {
                    Task { await Server.shared.respond(to: request, on: connection) }
                } else if isComplete || error != nil || buffer.count > 1 << 24 {
                    connection.cancel()
                } else {
                    Server.shared.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to request: Request, on connection: NWConnection) async {
        let response: Response
        switch (request.method, request.path) {
        case ("GET", "/v1/voices"):
            response = .json(["voices": Library.shared.allVoices.map(Self.describe)])
        case ("GET", "/v1/models"):
            response = .json(["object": "list", "data": Engine.allCases.map { ["id": $0.rawValue, "object": "model", "name": $0.name] }])
        case ("POST", "/v1/audio/speech"):
            response = await speech(request.body)
        case ("POST", "/v1/audio/transcriptions"):
            response = await transcription(request)
        case ("OPTIONS", _):
            response = Response(status: 204, type: "text/plain", body: Data())
        default:
            response = .error(404, "No route for \(request.method) \(request.path). Try POST /v1/audio/speech or GET /v1/voices.")
        }
        connection.send(content: response.data, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// `{"input": "…", "voice": "name or id", "model": "engine id", "instructions": "…"}` → WAV.
    private func speech(_ body: Data) async -> Response {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let input = json["input"] as? String, !input.isEmpty
        else { return .error(400, "Send JSON with an \"input\" string.") }
        let library = Library.shared
        let name = json["voice"] as? String ?? ""
        let engine = (json["model"] as? String).flatMap(Engine.init(rawValue:))
        let request: SpeechRequest
        if let voice = library.voice(named: name) ?? (name.isEmpty ? library.voice(id: Prefs.defaultVoice) ?? Voice.presets.first : nil) {
            request = .make(input, voice: voice, engine: engine, direction: json["instructions"] as? String)
        } else if let engine, engine.designs {
            // With a design engine, a voice that isn't in the library is a description of one.
            request = SpeechRequest(text: input, engine: engine, voice: name)
        } else {
            return .error(400, "No voice named \"\(name)\". GET /v1/voices lists them, or pick a design model and describe one.")
        }
        do {
            let samples = try await Generator.shared.render([.init(text: input, request: request, voiceName: name)], report: false)
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try WAV.write(samples, sampleRate: Generator.sampleRate, to: url)
            return Response(status: 200, type: "audio/wav", body: try Data(contentsOf: url))
        } catch {
            return .error(500, HubToken.explain(error, for: request.engine))
        }
    }

    /// A multipart upload with a "file" field, as OpenAI clients send it, or the audio as the raw body.
    private func transcription(_ request: Request) async -> Response {
        let form = request.multipart
        guard let audio = form["file"] ?? (request.body.isEmpty ? nil : request.body) else {
            return .error(400, "Send the audio as a multipart \"file\" field.")
        }
        // AVFoundation goes by the extension to pick a decoder.
        let filename = form["file.filename"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let fileExtension = URL(fileURLWithPath: filename).pathExtension
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(fileExtension.isEmpty ? "wav" : fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try audio.write(to: url)
            let language = form["language"].flatMap { String(data: $0, encoding: .utf8) }
            let transcript = try await ModelStore.shared.track(.whisper) { try await Transcriber.shared.transcribe(url, language: language) }
            switch form["response_format"].flatMap({ String(data: $0, encoding: .utf8) }) {
            case "text": return Response(status: 200, type: "text/plain; charset=utf-8", body: Data(transcript.text.utf8))
            case "srt": return Response(status: 200, type: "text/plain; charset=utf-8", body: Data(transcript.srt.utf8))
            case "verbose_json":
                return .json(["text": transcript.text, "language": transcript.language as Any? ?? NSNull(),
                              "segments": transcript.segments.map { ["start": $0.start, "end": $0.end, "text": $0.text] }])
            default: return .json(["text": transcript.text])
            }
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    private static func describe(_ voice: Voice) -> [String: Any] {
        ["id": voice.id, "name": voice.name, "origin": voice.origin.rawValue, "engine": voice.engine.rawValue,
         "engines": voice.engines.map(\.rawValue), "language": voice.language as Any? ?? NSNull()]
    }
}

private struct Request {
    var method: String
    var path: String
    var contentType = ""
    var body: Data

    /// The fields of a multipart/form-data body, by name.
    var multipart: [String: Data] {
        guard let range = contentType.range(of: "boundary=") else { return [:] }
        let boundary = Data(("--" + contentType[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))).utf8)
        var fields: [String: Data] = [:]
        var cursor = body.startIndex
        while let start = body.range(of: boundary, in: cursor..<body.endIndex) {
            guard let headEnd = body.range(of: Data("\r\n\r\n".utf8), in: start.upperBound..<body.endIndex),
                  let next = body.range(of: boundary, in: headEnd.upperBound..<body.endIndex)
            else { break }
            let head = String(decoding: body[start.upperBound..<headEnd.lowerBound], as: UTF8.self)
            if let nameRange = head.range(of: "name=\"") {
                let name = String(head[nameRange.upperBound...].prefix { $0 != "\"" })
                // Each part's content ends with CRLF before the next boundary.
                fields[name] = Data(body[headEnd.upperBound..<max(headEnd.upperBound, next.lowerBound - 2)])
                if let fileRange = head.range(of: "filename=\"") {
                    fields[name + ".filename"] = Data(head[fileRange.upperBound...].prefix { $0 != "\"" }.utf8)
                }
            }
            cursor = next.lowerBound
        }
        return fields
    }

    /// Nil until the headers and the whole body have arrived.
    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        method = String(start[0])
        contentType = headers["content-type"] ?? ""
        path = String(start[1].split(separator: "?").first ?? "")
        self.body = Data(body.prefix(length))
    }
}

private struct Response {
    var status: Int
    var type: String
    var body: Data

    static func json(_ object: Any) -> Response {
        Response(status: 200, type: "application/json", body: (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data())
    }

    static func error(_ status: Int, _ message: String) -> Response {
        var response = json(["error": ["message": message]])
        response.status = status
        return response
    }

    var data: Data {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found", 500: "Internal Server Error"][status] ?? ""
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
