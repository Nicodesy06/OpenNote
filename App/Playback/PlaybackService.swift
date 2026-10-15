import AVFoundation
import MediaPlayer
import Observation
import os

/// Riproduzione delle registrazioni con navigazione temporale, velocità
/// variabile e controlli nella schermata di blocco. L'osservazione del tempo
/// è attiva solo mentre una vista la richiede (`startObservingTime`).
@MainActor
@Observable
final class PlaybackService {
    private(set) var currentRecordingID: UUID?
    private(set) var title = ""
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Float = 1
    private(set) var errorMessage: String?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observerCount = 0
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private let logger = Logger(subsystem: "QuadernoAI", category: "Playback")
    /// Se una registrazione è in corso la sessione audio non va toccata.
    @ObservationIgnored var isRecordingActive: () -> Bool = { false }

    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    init() {
        configureRemoteCommands()
    }

    func load(recordingID: UUID, title: String, asset: AVAsset, knownDuration: TimeInterval) {
        if currentRecordingID == recordingID, player != nil { return }
        stop()
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        currentRecordingID = recordingID
        self.title = title
        duration = knownDuration
        currentTime = 0
        errorMessage = nil
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.updateNowPlaying()
            }
        }
        if observerCount > 0 { installTimeObserver() }
        Task {
            if let loaded = try? await asset.load(.duration), loaded.isValid, loaded.seconds > 0 {
                self.duration = loaded.seconds
            }
        }
    }

    func play() {
        guard let player else { return }
        if !isRecordingActive() {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
        }
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        currentTime = player?.currentTime().seconds ?? currentTime
        updateNowPlaying()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, max(duration, 0)))
        currentTime = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: (player?.currentTime().seconds ?? currentTime) + seconds)
    }

    func setRate(_ value: Float) {
        rate = value
        if isPlaying { player?.rate = value }
        updateNowPlaying()
    }

    func stop() {
        player?.pause()
        removeTimeObserver()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
        isPlaying = false
        currentRecordingID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if !isRecordingActive() {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Osservazione del tempo (solo con interfaccia visibile)

    func startObservingTime() {
        observerCount += 1
        if observerCount == 1 { installTimeObserver() }
    }

    func stopObservingTime() {
        observerCount = max(0, observerCount - 1)
        if observerCount == 0 { removeTimeObserver() }
    }

    private func installTimeObserver() {
        guard let player, timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    // MARK: - Schermata di blocco

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: 15) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -15) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard currentRecordingID != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime().seconds ?? currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0
        ]
    }
}
