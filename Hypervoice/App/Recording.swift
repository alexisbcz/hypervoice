#if DEBUG
import AppKit
import AVFoundation

/// For demo videos: `HYPERVOICE_RECORD=/some/demo.mov` films the window while `HYPERVOICE_DRAFT` is typed
/// into Speech and generated in `HYPERVOICE_VOICE`, then quits. The window stays behind other apps and never
/// takes focus, and speech is silent with `HYPERVOICE_MUTE`: the clip's audio goes in afterwards, starting at
/// the `audioStart` written next to the movie, along with the clip's path.
enum Recording {
    static func run(_ studio: Studio, to url: URL) {
        let environment = ProcessInfo.processInfo.environment
        let draft = environment["HYPERVOICE_DRAFT"] ?? ""
        // Keep drawing and the frame timer on schedule while the window is hidden behind others.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Recording a demo")
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) else { return NSApp.terminate(nil) }
            window.orderBack(nil)
            studio.section = .speech
            if let voice = environment["HYPERVOICE_VOICE"].flatMap(Library.shared.voice(named:)) { studio.voiceID = voice.id }
            studio.draft = ""
            // A first generation loads the model and warms it up; do that off camera, and keep it out of History.
            if let voice = studio.voice {
                Generator.shared.run([.init(text: draft, request: .make(draft, voice: voice), voiceName: voice.name)], title: "", save: false)
                while Generator.shared.isGenerating || Player.shared.playing != nil { try? await Task.sleep(for: .milliseconds(50)) }
            }
            try? await Task.sleep(for: .seconds(1))

            let film = Film(url: url, window: CGWindowID(window.windowNumber))
            film.start()
            try? await Task.sleep(for: .seconds(1))
            for character in draft {
                studio.draft.append(character)
                try? await Task.sleep(for: .milliseconds(character == " " ? 55 : Int.random(in: 25...45)))
            }
            try? await Task.sleep(for: .seconds(0.8))
            studio.generate()
            while Player.shared.playing != Player.live, Generator.shared.isGenerating || Generator.shared.lastClip == nil {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let audioStart = film.elapsed
            while Generator.shared.isGenerating || Player.shared.playing != nil { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .seconds(1.5))
            await film.finish()

            let clip = Generator.shared.lastClip.map { Library.shared.url(of: $0).path } ?? ""
            let notes: [String: Any] = ["audioStart": audioStart, "clip": clip, "error": Generator.shared.error ?? ""]
            try? JSONSerialization.data(withJSONObject: notes, options: .prettyPrinted)
                .write(to: url.deletingPathExtension().appendingPathExtension("json"))
            ProcessInfo.processInfo.endActivity(activity)
            NSApp.terminate(nil)
        }
    }

    /// Thirty frames a second of one window, shadow and transparency included, as ProRes 4444.
    private final class Film {
        private let url: URL
        private let window: CGWindowID
        private var writer: AVAssetWriter?
        private var input: AVAssetWriterInput?
        private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        private var timer: Timer?
        private var origin = CACurrentMediaTime()

        init(url: URL, window: CGWindowID) {
            self.url = url
            self.window = window
        }

        var elapsed: Double { CACurrentMediaTime() - origin }

        func start() {
            guard let first = Snapshot.capture(window) else { return }
            try? FileManager.default.removeItem(at: url)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.proRes4444,
                AVVideoWidthKey: first.width,
                AVVideoHeightKey: first.height,
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: first.width,
                kCVPixelBufferHeightKey as String: first.height,
            ])
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            (self.writer, self.input, self.adaptor) = (writer, input, adaptor)
            origin = CACurrentMediaTime()
            append(first, at: 0)
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
                MainActor.assumeIsolated { self.frame() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func frame() {
            let time = elapsed
            guard let image = Snapshot.capture(window) else { return }
            append(image, at: time)
        }

        private func append(_ image: CGImage, at time: Double) {
            guard let input, let adaptor, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
        }

        func finish() async {
            timer?.invalidate()
            frame()
            input?.markAsFinished()
            await writer?.finishWriting()
        }
    }
}
#endif
