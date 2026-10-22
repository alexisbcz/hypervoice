import AVFoundation
import Observation

/// Plays one thing at a time: speech as it generates, or a saved clip.
@Observable
final class Player {
    static let shared = Player()

    /// What's playing: a clip's id, or `live` while generated speech streams in.
    private(set) var playing: String?
    /// Seconds into what's playing: a saved clip, or the live stream so far.
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    var rate: Float = 1 {
        didSet { timePitch.rate = rate; clip?.rate = rate }
    }

    static let live = "live"

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private var format: AVAudioFormat?
    @ObservationIgnored private var pending = 0
    @ObservationIgnored private var isFinishing = false
    /// Playing generated speech through the node, under `live` or the id of the clip it was saved as.
    @ObservationIgnored private var streaming = false
    /// Bumped by every start and stop: stopping the node fires the callbacks of buffers it drops,
    /// and those mustn't count against what plays next.
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var clip: AVAudioPlayer?
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private let clipDelegate = ClipDelegate()

    init() {
        engine.attach(node)
        engine.attach(timePitch)
        clipDelegate.onFinish = { [weak self] in self?.stop() }
        #if DEBUG
        // HYPERVOICE_MUTE keeps test runs silent.
        if ProcessInfo.processInfo.environment["HYPERVOICE_MUTE"] != nil { engine.mainMixerNode.outputVolume = 0 }
        #endif
    }

    func isPlaying(_ id: String) -> Bool { playing == id }

    // MARK: - Live

    /// Starts a stream at the engine's sample rate; `enqueue` adds speech as it's generated.
    func startStream(sampleRate: Int) throws {
        stop()
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        if self.format != format {
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(node, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            self.format = format
        }
        timePitch.rate = rate
        run += 1
        pending = 0
        isFinishing = false
        if !engine.isRunning { try engine.start() }
        node.play()
        playing = Self.live
        streaming = true
        duration = 0
        clock = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { Player.shared.tickStream() }
        }
    }

    /// The node counts what it has played, at the stream's own rate whatever the playback speed.
    private func tickStream() {
        guard let now = node.lastRenderTime, let time = node.playerTime(forNodeTime: now), time.sampleRate > 0 else { return }
        position = min(Double(time.sampleTime) / time.sampleRate, duration)
    }

    /// The live stream becomes `id`'s, once what it's playing has been saved under that id.
    func adopt(_ id: String) {
        if playing == Self.live { playing = id }
    }

    func enqueue(_ samples: [Float]) {
        guard streaming, playing == Self.live, let format, let buffer = WAV.buffer(samples, sampleRate: Int(format.sampleRate)) else { return }
        pending += 1
        duration += Double(samples.count) / format.sampleRate
        let run = run
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: Self.onMain { [weak self] in
            self?.played(run)
        })
    }

    /// Nothing more is coming: the stream ends once what's queued has played.
    func finishStream() {
        isFinishing = true
        if pending == 0, streaming { stop() }
    }

    /// Built outside the main actor: the audio thread calls it, and a main-actor closure would trap there.
    nonisolated private static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in DispatchQueue.main.async { MainActor.assumeIsolated { body() } } }
    }

    private func played(_ run: Int) {
        guard run == self.run else { return }
        pending = max(0, pending - 1)
        if isFinishing, pending == 0 { stop() }
    }

    // MARK: - Clips

    func toggle(_ clip: Clip) {
        if isPlaying(clip.id.uuidString) { stop() } else { play(Library.shared.url(of: clip), id: clip.id.uuidString) }
    }

    func play(_ url: URL, id: String) {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.enableRate = true
        player.rate = rate
        player.delegate = clipDelegate
        player.play()
        clip = player
        playing = id
        duration = player.duration
        position = 0
        clock = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { _ in
            MainActor.assumeIsolated { Player.shared.position = Player.shared.clip?.currentTime ?? 0 }
        }
    }

    func seek(to fraction: Double) {
        guard let clip else { return }
        clip.currentTime = fraction * clip.duration
        position = clip.currentTime
    }

    func stop() {
        run += 1
        pending = 0
        isFinishing = false
        streaming = false
        node.stop()
        clip?.stop()
        clip = nil
        clock?.invalidate()
        clock = nil
        playing = nil
        position = 0
    }
}

private final class ClipDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onFinish?() } }
    }
}

/// Records a voice sample from the microphone, with a live level for the meter.
@Observable
final class Recorder {
    private(set) var isRecording = false
    /// The last finished recording, including one stopped by the time limit.
    private(set) var recording: URL?
    private(set) var elapsed: Double = 0
    /// Recent loudness, 0...1, newest last.
    private(set) var levels: [Float] = []
    var error: String?

    static let maximum: Double = 30

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meter: Timer?

    func start() async -> Bool {
        error = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "Allow the microphone for Hypervoice in System Settings › Privacy & Security."
            return false
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "Hypervoice recording \(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.maximum) else {
                error = "Couldn't start recording."
                return false
            }
            self.recorder = recorder
        } catch {
            self.error = error.localizedDescription
            return false
        }
        isRecording = true
        elapsed = 0
        levels = []
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        return true
    }

    /// Stops and returns the recording.
    func stop() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        meter?.invalidate()
        meter = nil
        isRecording = false
        self.recorder = nil
        recording = recorder.url
        return recorder.url
    }

    private func sample() {
        guard let recorder else { return }
        guard recorder.isRecording else {
            _ = stop()
            return
        }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        levels.append(max(0, min(1, (decibels + 50) / 50)))
        if levels.count > 120 { levels.removeFirst(levels.count - 120) }
        elapsed = recorder.currentTime
    }
}
