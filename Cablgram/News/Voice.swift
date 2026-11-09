import Foundation
import AVFoundation

// MARK: - Shared marks

/// A voice note pinned to a spot on a photo.
struct VoiceNote: Identifiable, Equatable {
    let id: String
    let author: String
    let authorID: String?
    let x: Double
    let y: Double
    let seconds: Double
    let audio: Data

    var firstName: String { author.components(separatedBy: " ").first ?? author }

    static func == (lhs: VoiceNote, rhs: VoiceNote) -> Bool { lhs.id == rhs.id }
}

// MARK: - Recording

/// Records one voice note (up to 10 seconds) while a finger is held down,
/// and reports how loud you are so the UI can pulse with your voice.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    static let maxSeconds: TimeInterval = 10

    @Published private(set) var isRecording = false
    /// 0 (quiet) to 1 (shouting).
    @Published private(set) var level: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var meter: Timer?
    private var lastWholeSecond = 0
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("cablgram-voice.m4a")

    var hasPermission: Bool { AVAudioApplication.shared.recordPermission == .granted }
    var wasDenied: Bool { AVAudioApplication.shared.recordPermission == .denied }

    /// Asks for the microphone once, when Voice is first picked.
    func requestPermission() async -> Bool {
        if hasPermission { return true }
        return await AVAudioApplication.requestRecordPermission()
    }

    @discardableResult
    func start() -> Bool {
        guard hasPermission, !isRecording else { return false }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)

        // Small AAC, so a 10-second note is about 40 KB.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        recorder.isMeteringEnabled = true
        recorder.record(forDuration: Self.maxSeconds)
        self.recorder = recorder
        startedAt = .now
        elapsed = 0
        lastWholeSecond = 0
        isRecording = true
        meter = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return true
    }

    private func tick() {
        guard let recorder, let startedAt else { return }
        elapsed = min(Date.now.timeIntervalSince(startedAt), Self.maxSeconds)
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        level = min(max((decibels + 50) / 45, 0), 1)
        // A tick every second, so you can feel the time passing.
        let whole = Int(elapsed)
        if whole > lastWholeSecond {
            lastWholeSecond = whole
            Haptics.tap()
        }
    }

    /// Stops and returns the recording, or nil if it was too short.
    func stop() -> (audio: Data, seconds: Double)? {
        guard let recorder, let startedAt else { return nil }
        let seconds = min(Date.now.timeIntervalSince(startedAt), Self.maxSeconds)
        recorder.stop()
        meter?.invalidate()
        meter = nil
        self.recorder = nil
        self.startedAt = nil
        isRecording = false
        level = 0
        let data = try? Data(contentsOf: url)
        // Turning the audio session off can take a moment; don't hold up the UI.
        DispatchQueue.global(qos: .utility).async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        guard seconds >= 0.6, let data else { return nil }
        return (data, seconds)
    }
}

// MARK: - Playback

/// Plays voice notes, one at a time or all in a row.
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: String?

    private var player: AVAudioPlayer?
    private var queue: [VoiceNote] = []

    func toggle(_ note: VoiceNote) {
        if playingID == note.id { stop() } else { queue = []; start(note) }
    }

    func playAll(_ notes: [VoiceNote]) {
        guard let first = notes.first else { return }
        queue = Array(notes.dropFirst())
        start(first)
    }

    func stop() {
        player?.stop()
        player = nil
        queue = []
        playingID = nil
    }

    private func start(_ note: VoiceNote) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(data: note.audio)
        player?.delegate = self
        player?.volume = 1
        if player?.play() == true {
            playingID = note.id
        } else {
            next()
        }
    }

    private func next() {
        if queue.isEmpty {
            player = nil
            playingID = nil
        } else {
            start(queue.removeFirst())
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.next() }
    }
}
