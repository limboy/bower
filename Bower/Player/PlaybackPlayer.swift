import AVFoundation
import Observation

/// Keeps one set of transport controls while choosing local or YouTube media.
@Observable
final class PlaybackPlayer {
    let youtube = YouTubePlayer()
    private let local = LocalVideoPlayer()
    private(set) var localFileURL: URL?

    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private var videoID: String?
    @ObservationIgnored private var failedLocalURL: URL?
    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored var onStartedPlaying: (() -> Void)?
    @ObservationIgnored var onProgress: ((Double, Double) -> Void)?
    @ObservationIgnored var onSourceChanged: (() -> Void)?

    var isLocal: Bool { localFileURL != nil }
    var localAVPlayer: AVPlayer? { isLocal ? local.player : nil }
    var isPlaying: Bool { isLocal ? local.isPlaying : youtube.isPlaying }
    var currentTime: Double { isLocal ? local.currentTime : youtube.currentTime }
    var duration: Double { isLocal ? local.duration : youtube.duration }

    init(downloads: DownloadManager) {
        self.downloads = downloads
        youtube.onEnded = { [weak self] in
            guard let self, !isLocal else { return }
            onEnded?()
        }
        youtube.onStartedPlaying = { [weak self] in
            guard let self, !isLocal else { return }
            onStartedPlaying?()
        }
        youtube.onProgress = { [weak self] time, duration in
            guard let self, !isLocal else { return }
            onProgress?(time, duration)
        }
        local.onEnded = { [weak self] in
            guard let self, isLocal else { return }
            onEnded?()
        }
        local.onStartedPlaying = { [weak self] in
            guard let self, isLocal else { return }
            onStartedPlaying?()
        }
        local.onProgress = { [weak self] time, duration in
            guard let self, isLocal else { return }
            onProgress?(time, duration)
        }
        local.onFailure = { [weak self] in self?.fallBackToYouTube() }
    }

    func load(videoID: String, startAt: Double?, autoplay: Bool) {
        self.videoID = videoID
        failedLocalURL = nil
        localFileURL = downloads.completedItem(for: videoID)?.fileURL
        if let localFileURL {
            youtube.stop()
            local.load(url: localFileURL, startAt: startAt, autoplay: autoplay)
        } else {
            local.stop()
            youtube.load(videoID: videoID, startAt: startAt, autoplay: autoplay)
        }
    }

    /// Completing or removing a download changes the source at the same position.
    func refreshDownloadSource() {
        guard let videoID else { return }
        let downloadedURL = downloads.completedItem(for: videoID)?.fileURL
        let availableURL = downloadedURL == failedLocalURL ? nil : downloadedURL
        guard availableURL != localFileURL else { return }
        let position = currentTime
        let autoplay = isPlaying
        load(videoID: videoID, startAt: position, autoplay: autoplay)
        onSourceChanged?()
    }

    private func fallBackToYouTube() {
        guard let videoID, isLocal else { return }
        let position = local.currentTime
        let autoplay = local.wantsToPlay
        failedLocalURL = localFileURL
        localFileURL = nil
        local.stop()
        youtube.load(videoID: videoID, startAt: position, autoplay: autoplay)
        onSourceChanged?()
    }

    func play() { isLocal ? local.play() : youtube.play() }
    func pause() { isLocal ? local.pause() : youtube.pause() }
    func togglePlayPause() { isPlaying ? pause() : play() }
    func seek(to seconds: Double) { isLocal ? local.seek(to: seconds) : youtube.seek(to: seconds) }
    func restart() { isLocal ? local.restart() : youtube.restart() }
    func reload() { youtube.reload() }

    func stop() {
        videoID = nil
        localFileURL = nil
        failedLocalURL = nil
        local.stop()
        youtube.stop()
    }
}

/// Bridges native player controls and playback events into the shared model.
@Observable
private final class LocalVideoPlayer {
    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    @ObservationIgnored var wantsToPlay = false
    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored var onStartedPlaying: (() -> Void)?
    @ObservationIgnored var onProgress: ((Double, Double) -> Void)?
    @ObservationIgnored var onFailure: (() -> Void)?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var playingObservation: NSKeyValueObservation?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reportedPlaying = false

    init() {
        playingObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updatePlaying() }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateProgress() }
        }
    }

    isolated deinit {
        seekTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(url: URL, startAt: Double?, autoplay: Bool) {
        stop()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        let generation = generation
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                if self.player.currentItem?.status == .failed {
                    self.onFailure?()
                } else {
                    self.updateProgress()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.isPlaying = false
                self.wantsToPlay = false
                self.onEnded?()
            }
        }
        wantsToPlay = autoplay
        isPlaying = autoplay
        if let startAt, startAt > 0.1 {
            seek(to: startAt, autoplay: autoplay)
        } else {
            currentTime = 0
            if autoplay { player.play() }
        }
    }

    func play() {
        guard player.currentItem != nil else { return }
        wantsToPlay = true
        if duration > 0 && currentTime >= duration - 0.1 {
            restart()
        } else {
            player.play()
        }
    }

    func pause() {
        wantsToPlay = false
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) { seek(to: seconds, autoplay: true) }

    private func seek(to seconds: Double, autoplay: Bool) {
        seekTask?.cancel()
        player.currentItem?.cancelPendingSeeks()
        currentTime = seconds.isFinite ? max(0, seconds) : 0
        wantsToPlay = autoplay
        let time = CMTime(seconds: currentTime, preferredTimescale: 600)
        let generation = generation
        seekTask = Task { [weak self] in
            guard let self else { return }
            let finished = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, self.generation == generation, finished else { return }
            seekTask = nil
            updateProgress()
            if wantsToPlay { player.play() }
        }
    }

    func restart() {
        reportedPlaying = false
        seek(to: 0)
    }

    func stop() {
        generation += 1
        seekTask?.cancel()
        seekTask = nil
        wantsToPlay = false
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        duration = 0
        reportedPlaying = false
    }

    private func updatePlaying() {
        guard player.currentItem != nil else { return }
        let status = player.timeControlStatus
        isPlaying = status == .playing || status == .waitingToPlayAtSpecifiedRate
        if seekTask == nil { wantsToPlay = isPlaying }
        if status == .playing && !reportedPlaying {
            reportedPlaying = true
            onStartedPlaying?()
        }
    }

    private func updateProgress() {
        guard seekTask == nil, let item = player.currentItem else { return }
        let time = player.currentTime().seconds
        let total = item.duration.seconds
        if time.isFinite { currentTime = max(0, time) }
        if total.isFinite && total > 0 { duration = total }
        onProgress?(currentTime, duration)
    }
}
