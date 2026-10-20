import AppKit

/// A script: lines of speech, each spoken by whoever was last named, with pauses and sound effects between.
///
///     @Heart Welcome back to the show.
///     George: Which, honestly, is the only way I'd want it.
///     [pause 1.5s]
///     [sound Applause]
///
/// A line starting with `@Name` or `Name:` switches speaker. `[pause]`, `[pause 2s]` and `[pause 500ms]` add
/// silence; `[sound Name]` plays a sound from the Sounds list. Any other bracket, like Chatterbox's `[laugh]`,
/// stays in the text for the engine to read.
struct Script {
    enum Cue {
        case speech(speaker: String, voice: Voice?, text: String)
        case pause(Double)
        case sound(name: String, sound: Sound?)
    }

    /// A stretch of the text the editor colors.
    struct Token {
        enum Kind {
            /// `name` is how it's written, without the `@` or colon.
            case speaker(name: String, voice: Voice?)
            case pause
            case sound(Sound?)
        }

        var range: NSRange
        var kind: Kind
    }

    struct Speaker: Identifiable {
        var name: String
        var voice: Voice?
        var lines: Int
        var id: String { name.lowercased() }
    }

    private(set) var cues: [Cue] = []
    private(set) var tokens: [Token] = []

    static let defaultPause = 0.75

    init(_ text: String, library: Library, fallback: Voice?) {
        let sounds = Sounds.all
        let string = text as NSString
        var speaker = fallback?.name ?? ""
        var voice = fallback
        var location = 0
        while location < string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)
            var cursor = lineRange.location
            let end = lineRange.location + (string.substring(with: lineRange) as NSString)
                .trimmingCharacters(in: .newlines).utf16.count
            while cursor < end, Self.isSpace(string.character(at: cursor)) { cursor += 1 }
            guard cursor < end else { continue }

            if let marker = Self.speakerMarker(in: string, at: cursor, end: end, library: library) {
                speaker = marker.name
                voice = marker.voice
                tokens.append(Token(range: marker.range, kind: .speaker(name: marker.name, voice: marker.voice)))
                cursor = NSMaxRange(marker.range)
            }

            // The rest of the line: speech, split around any pause or sound.
            let rest = NSRange(location: cursor, length: end - cursor)
            var textStart = cursor
            for match in Self.directive.matches(in: text, range: rest) {
                append(speech: string.substring(with: NSRange(location: textStart, length: match.range.location - textStart)), speaker, voice)
                let kind = string.substring(with: match.range(at: 1)).lowercased()
                let argument = match.range(at: 2).location == NSNotFound ? "" : string.substring(with: match.range(at: 2))
                if kind == "pause" || kind == "break" {
                    cues.append(.pause(Self.seconds(argument)))
                    tokens.append(Token(range: match.range, kind: .pause))
                } else {
                    let name = argument.trimmingCharacters(in: .whitespaces)
                    let sound = sounds.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    cues.append(.sound(name: name, sound: sound))
                    tokens.append(Token(range: match.range, kind: .sound(sound)))
                }
                textStart = NSMaxRange(match.range)
            }
            append(speech: string.substring(with: NSRange(location: textStart, length: end - textStart)), speaker, voice)
        }
    }

    /// Joins speech to the previous cue when the same speaker carries on, so sentences flow together.
    private mutating func append(speech: String, _ speaker: String, _ voice: Voice?) {
        let text = speech.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if case .speech(let last, let lastVoice, let previous) = cues.last, last == speaker {
            cues[cues.count - 1] = .speech(speaker: last, voice: lastVoice, text: previous + "\n" + text)
        } else {
            cues.append(.speech(speaker: speaker, voice: voice, text: text))
        }
    }

    /// Everyone who speaks, in order of first appearance, with how many lines they start.
    var speakers: [Speaker] {
        var speakers: [Speaker] = []
        for cue in cues {
            guard case .speech(let name, let voice, _) = cue, !speakers.contains(where: { $0.id == name.lowercased() }) else { continue }
            speakers.append(Speaker(name: name, voice: voice, lines: 0))
        }
        for token in tokens {
            guard case .speaker(let name, _) = token.kind,
                  let index = speakers.firstIndex(where: { $0.id == name.lowercased() }) else { continue }
            speakers[index].lines += 1
        }
        // The fallback voice speaks lines that come before anyone is named.
        for index in speakers.indices where speakers[index].lines == 0 { speakers[index].lines = 1 }
        return speakers
    }

    var duration: Double {
        cues.reduce(0) { total, cue in
            if case .pause(let seconds) = cue { return total + seconds }
            return total
        }
    }

    // MARK: - Parsing

    private static let directive = try! NSRegularExpression(pattern: #"\[(pause|break|sound|sfx)(?:[\s:]+([^\]]*))?\s*\]"#, options: .caseInsensitive)

    /// `@Name`, matching the longest voice name so "@Uncle Fu" works, else `@Word`; or `Name:` as in a screenplay.
    private static func speakerMarker(in string: NSString, at start: Int, end: Int, library: Library) -> (name: String, voice: Voice?, range: NSRange)? {
        let line = string.substring(with: NSRange(location: start, length: end - start))
        if line.hasPrefix("@") {
            let afterAt = line.dropFirst()
            let names = library.allVoices.map(\.name).sorted { $0.count > $1.count }
            for name in names where afterAt.lowercased().hasPrefix(name.lowercased()) {
                let next = afterAt.dropFirst(name.count).first
                guard next == nil || next == " " || next == ":" || next == "," || next == "\t" else { continue }
                let length = 1 + name.utf16.count + (next == ":" ? 1 : 0)
                let written = String(afterAt.prefix(name.count))
                return (written, library.voice(named: name), NSRange(location: start, length: length))
            }
            let word = afterAt.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "'" }
            guard !word.isEmpty else { return nil }
            let colon = afterAt.dropFirst(word.count).first == ":" ? 1 : 0
            return (String(word), nil, NSRange(location: start, length: 1 + word.utf16.count + colon))
        }
        guard let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 32 else { return nil }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains(where: { ".!?[]".contains($0) }) else { return nil }
        return (name, library.voice(named: name), NSRange(location: start, length: line[...colon].utf16.count))
    }

    /// "1.5s", "500ms", "2", or nothing for the default.
    static func seconds(_ argument: String) -> Double {
        let value = argument.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return defaultPause }
        let seconds = value.hasSuffix("ms")
            ? Double(value.dropLast(2).trimmingCharacters(in: .whitespaces)).map { $0 / 1000 }
            : Double(value.trimmingCharacters(in: CharacterSet(charactersIn: "sec ")))
        return min(30, max(0, seconds ?? defaultPause))
    }

    private static func isSpace(_ character: unichar) -> Bool { character == 0x20 || character == 0x09 }
}

/// A sound effect a script can play: the Mac's own alert sounds, plus any audio you add.
struct Sound: Identifiable, Hashable, Sendable {
    var name: String
    var url: URL
    var isBuiltIn: Bool
    var id: URL { url }
}

enum Sounds {
    static let folder = Library.folder.appending(path: "Sounds", directoryHint: .isDirectory)
    private static let system = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    /// Yours first, then the system's, each by name.
    static var all: [Sound] { list(folder, builtIn: false) + list(system, builtIn: true) }

    private static func list(_ folder: URL, builtIn: Bool) -> [Sound] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { ["aiff", "aif", "wav", "mp3", "m4a", "caf", "flac"].contains($0.pathExtension.lowercased()) }
            .map { Sound(name: $0.deletingPathExtension().lastPathComponent, url: $0, isBuiltIn: builtIn) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Copies the files in; a sound is then used by its file name, like `[sound Applause]`.
    static func add(_ urls: [URL]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in urls {
            let destination = folder.appending(path: url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: url, to: destination)
        }
    }

    static func delete(_ sound: Sound) {
        guard !sound.isBuiltIn else { return }
        try? FileManager.default.removeItem(at: sound.url)
    }
}
