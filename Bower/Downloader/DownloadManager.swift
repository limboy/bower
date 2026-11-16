import AppKit
import Foundation
import Observation
import Synchronization

@Observable
final class DownloadManager {
    private(set) var items: [DownloadItem] = []
    private(set) var liveStats: [String: DownloadLiveStats] = [:]
    private(set) var revision = 0

    var preferredQuality: DownloadQuality {
        didSet { UserDefaults.standard.set(preferredQuality.rawValue, forKey: Self.qualityDefaultsKey) }
    }

    var downloadsDirectory: URL {
        AppPaths.defaultDownloadsDirectory
    }

    @ObservationIgnored private var activeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pauseRequested: Set<String> = []
    @ObservationIgnored private var cancelRequested: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static let maxConcurrent = 2
    private static let qualityDefaultsKey = "downloadQuality"

    init() {
        let rawQuality = UserDefaults.standard.string(forKey: Self.qualityDefaultsKey) ?? DownloadQuality.best.rawValue
        preferredQuality = DownloadQuality(rawValue: rawQuality) ?? .best

        if let loaded = JSONFile.read([DownloadItem].self, from: AppPaths.downloads) {
            items = loaded.map { item in
                var copy = item
                if copy.status.isActive {
                    copy.status = .paused
                }
                return copy
            }
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = items
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: AppPaths.downloads)
        }
    }

    @concurrent
    private static func write(_ items: [DownloadItem], to url: URL) async {
        JSONFile.write(items, to: url)
    }

    func flush() {
        if saveTask != nil {
            saveTask?.cancel()
            saveTask = nil
            JSONFile.write(items, to: AppPaths.downloads)
        }
    }

    // MARK: - Queries

    var activeCount: Int {
        items.reduce(0) { $0 + ($1.status.isActive ? 1 : 0) }
    }

    func activeItem(for videoID: String) -> DownloadItem? {
        items.first { $0.videoID == videoID && ($0.status.isActive || $0.status == .paused) }
    }

    func completedItem(for videoID: String) -> DownloadItem? {
        items.first { $0.videoID == videoID && $0.status == .completed && $0.fileExists }
    }

    func latestItem(for videoID: String) -> DownloadItem? {
        activeItem(for: videoID) ?? completedItem(for: videoID)
            ?? items.first { $0.videoID == videoID && ($0.status == .failed || $0.status == .cancelled) }
    }

    func progress(for item: DownloadItem) -> (downloaded: Int64, total: Int64, fraction: Double) {
        if item.status == .completed {
            return (item.fileSize, item.fileSize, 1)
        }
        if let stats = liveStats[item.id] {
            let total = stats.totalBytes > 0 ? stats.totalBytes : item.totalBytes
            let done = stats.downloadedBytes > 0 ? stats.downloadedBytes : item.downloadedBytes
            let fraction = total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0
            return (done, total, fraction)
        }
        return (item.downloadedBytes, item.totalBytes, item.fraction)
    }

    // MARK: - Enqueue

    @discardableResult
    func enqueue(video: Video, quality: DownloadQuality? = nil) -> DownloadItem {
        let chosenQuality = quality ?? preferredQuality

        // If already active or paused for this video, resume/return it instead of duplicating.
        if let existing = items.first(where: { $0.videoID == video.id && ($0.status.isActive || $0.status == .paused) }) {
            if existing.status == .paused {
                resume(id: existing.id)
            }
            return existing
        }

        // Replace any previous finished/failed entry for the same video so Downloads stays 1:1 with videoID.
        let stale = items.filter { $0.videoID == video.id }
        for old in stale {
            if let fileURL = old.fileURL, old.fileExists {
                try? FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            }
            cleanupWorkDir(for: old.id)
            liveStats.removeValue(forKey: old.id)
        }
        items.removeAll { $0.videoID == video.id }

        let item = DownloadItem(
            id: UUID().uuidString.lowercased(),
            videoID: video.id,
            title: video.title,
            author: video.sourceTitle,
            thumbnail: video.thumbnail,
            duration: video.duration,
            watchURL: video.watchURL.absoluteString,
            quality: chosenQuality,
            resolvedQualityLabel: nil,
            ext: chosenQuality == .audioOnly ? "m4a" : "mp4",
            filePath: nil,
            status: .queued,
            downloadedBytes: 0,
            totalBytes: 0,
            fileSize: 0,
            errorMessage: nil,
            createdAt: nowMilliseconds(),
            completedAt: nil
        )
        items.insert(item, at: 0)
        revision += 1
        scheduleSave()
        pumpQueue()
        return item
    }

    func enqueue(urlString: String, quality: DownloadQuality? = nil) async throws {
        guard let kind = YouTubeURL.classify(urlString) else {
            throw YouTubeError("Please enter a valid YouTube video or playlist URL.")
        }
        switch kind {
        case .unsupported(let reason):
            throw YouTubeError(reason)
        case .video(let videoID):
            let details = try await InnerTubeClient.shared.video(id: videoID)
            enqueue(video: details.video, quality: quality)
        case .playlist(let listID):
            let snapshot = try await InnerTubeClient.shared.playlist(id: listID, fullHistory: false)
            guard !snapshot.videos.isEmpty else {
                throw YouTubeError("No videos found in that playlist.")
            }
            for video in snapshot.videos.reversed() {
                var copy = video
                copy.sourceTitle = copy.sourceTitle ?? snapshot.title
                enqueue(video: copy, quality: quality)
            }
        case .channel:
            throw YouTubeError("Paste a specific video or playlist link to download.")
        }
    }

    // MARK: - Controls

    func pause(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].status == .queued {
            items[index].status = .paused
            liveStats.removeValue(forKey: id)
            revision += 1
            scheduleSave()
            return
        }
        guard items[index].status.isActive else { return }
        pauseRequested.insert(id)
        activeTasks[id]?.cancel()
    }

    func resume(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status == .paused || items[index].status == .failed || items[index].status == .cancelled
        else { return }
        items[index].status = .queued
        items[index].errorMessage = nil
        liveStats.removeValue(forKey: id)
        revision += 1
        scheduleSave()
        pumpQueue()
    }

    func retry(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        cleanupWorkDir(for: id)
        items[index].status = .queued
        items[index].downloadedBytes = 0
        items[index].totalBytes = 0
        items[index].errorMessage = nil
        liveStats.removeValue(forKey: id)
        revision += 1
        scheduleSave()
        pumpQueue()
    }

    func cancel(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if activeTasks[id] != nil {
            cancelRequested.insert(id)
            activeTasks[id]?.cancel()
        } else {
            cleanupWorkDir(for: id)
            items[index].status = .cancelled
            liveStats.removeValue(forKey: id)
            revision += 1
            scheduleSave()
        }
    }

    func remove(ids: Set<String>, trashFiles: Bool) throws {
        var removedIDs: Set<String> = []
        var failures: [String] = []

        for item in items where ids.contains(item.id) {
            do {
                if trashFiles, let fileURL = item.fileURL, item.fileExists {
                    try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                }
                removedIDs.insert(item.id)
            } catch {
                failures.append("“\(item.title)”: \(error.localizedDescription)")
            }
        }

        // Remove the whole selection before allowing another queued task to start.
        items.removeAll { removedIDs.contains($0.id) }
        for id in removedIDs {
            if let task = activeTasks[id] {
                cancelRequested.insert(id)
                task.cancel()
                // The task cleans up after its outstanding file writes stop.
            } else {
                cleanupWorkDir(for: id)
            }
            liveStats.removeValue(forKey: id)
        }
        if !removedIDs.isEmpty {
            revision += 1
            scheduleSave()
            pumpQueue()
        }
        if !failures.isEmpty {
            throw YouTubeError("Couldn't delete some downloads:\n\(failures.joined(separator: "\n"))")
        }
    }

    func pauseAll() {
        for item in items where item.status.isActive {
            pause(id: item.id)
        }
    }

    func resumeAll() {
        for item in items where item.status == .paused {
            resume(id: item.id)
        }
    }

    func clearCompleted() {
        items.removeAll { $0.status == .completed }
        revision += 1
        scheduleSave()
    }

    func clearFinishedAndFailed() {
        let toRemove = items.filter { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
        for item in toRemove where item.status != .completed {
            cleanupWorkDir(for: item.id)
        }
        items.removeAll { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
        revision += 1
        scheduleSave()
    }

    func revealInFinder(id: String) {
        guard let item = items.first(where: { $0.id == id }), let fileURL = item.fileURL, item.fileExists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func openDownloadsFolder() {
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(downloadsDirectory)
    }

    // MARK: - Queue Execution

    private func pumpQueue() {
        let runningCount = activeTasks.count
        guard runningCount < Self.maxConcurrent else { return }

        let slots = Self.maxConcurrent - runningCount
        // Start oldest queued items first (bottom of list) so FIFO feels natural.
        let queuedIDs = items.reversed()
            .filter { $0.status == .queued && activeTasks[$0.id] == nil }
            .prefix(slots).map(\.id)
        for id in queuedIDs {
            startTask(for: id)
        }
    }

    private func startTask(for id: String) {
        guard activeTasks[id] == nil,
              let item = items.first(where: { $0.id == id })
        else { return }

        let targetDir = downloadsDirectory
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(item: item, outputDirectory: targetDir)
        }
        activeTasks[id] = task
    }

    private func runDownload(item: DownloadItem, outputDirectory: URL) async {
        let id = item.id
        var unfinishedOutput: URL?
        defer {
            if let unfinishedOutput {
                for url in [unfinishedOutput,
                            unfinishedOutput.appendingPathExtension("muxtmp"),
                            unfinishedOutput.appendingPathExtension("tagtmp")] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            if !items.contains(where: { $0.id == id }) {
                cleanupWorkDir(for: id)
                liveStats.removeValue(forKey: id)
            }
            activeTasks.removeValue(forKey: id)
            pauseRequested.remove(id)
            cancelRequested.remove(id)
            pumpQueue()
        }

        do {
            try Task.checkCancellation()
            updateItem(id) {
                $0.status = .extracting
                $0.errorMessage = nil
            }
            liveStats[id] = DownloadLiveStats(stage: "Fetching video streams…")

            let media = try await YouTubeStreamExtractor.extract(videoID: item.videoID)
            try Task.checkCancellation()

            let selected = try YouTubeStreamExtractor.selectFormats(from: media, quality: item.quality)
            let isAudioOnly = item.quality == .audioOnly || (selected.video == nil && selected.audio != nil)
            let ext = isAudioOnly ? "m4a" : (selected.video?.ext == "webm" && selected.audio == nil ? "webm" : "mp4")
            let qualLabel: String = {
                if isAudioOnly { return "M4A Audio" }
                if let v = selected.video {
                    return v.height > 0 ? "\(v.height)p" : v.qualityLabel
                }
                return item.quality.shortLabel
            }()

            let resolvedTitle = media.title.isEmpty ? item.title : media.title
            let resolvedAuthor = media.author.isEmpty ? item.author : media.author
            let resolvedThumb = media.thumbnailURL.isEmpty ? item.thumbnail : media.thumbnailURL

            let expectedTotal: Int64 = (selected.video?.filesize ?? 0) + (selected.audio?.filesize ?? 0)
            updateItem(id) {
                $0.title = resolvedTitle
                $0.author = resolvedAuthor
                $0.thumbnail = resolvedThumb
                $0.ext = ext
                $0.resolvedQualityLabel = qualLabel
                if expectedTotal > 0, $0.totalBytes == 0 {
                    $0.totalBytes = expectedTotal
                }
                $0.status = .downloading
            }

            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let outputURL = uniqueOutputURL(in: outputDirectory, title: resolvedTitle, ext: ext)
            unfinishedOutput = outputURL
            let workDir = workDirectory(for: id)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            let tracker = ProgressTracker(
                initialVideoTotal: selected.video?.filesize ?? 0,
                initialAudioTotal: selected.audio?.filesize ?? 0
            ) { [weak self] combinedDone, combinedTotal, speed, eta in
                Task { @MainActor [weak self] in
                    guard let self,
                          let idx = self.items.firstIndex(where: { $0.id == id }),
                          self.items[idx].status == .downloading
                    else { return }
                    self.liveStats[id] = DownloadLiveStats(
                        downloadedBytes: combinedDone,
                        totalBytes: combinedTotal > 0 ? combinedTotal : self.items[idx].totalBytes,
                        speedBytesPerSec: speed,
                        etaSeconds: eta,
                        stage: "Downloading…"
                    )
                }
            }

            var vPath: URL?
            var aPath: URL?

            if let videoFmt = selected.video, let audioFmt = selected.audio {
                let vDest = workDir.appending(path: "video.\(videoFmt.ext)")
                let aDest = workDir.appending(path: "audio.\(audioFmt.ext)")
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await Self.downloadFormat(videoFmt, to: vDest, maxHeight: item.quality.maxHeight) { d, t in
                            tracker.update(isVideo: true, done: d, total: t)
                        }
                    }
                    group.addTask {
                        try await Self.downloadFormat(audioFmt, to: aDest, maxHeight: 0) { d, t in
                            tracker.update(isVideo: false, done: d, total: t)
                        }
                    }
                    try await group.waitForAll()
                }
                vPath = vDest
                aPath = aDest
            } else if let singleFmt = selected.video ?? selected.audio {
                let dest = workDir.appending(path: "stream.\(singleFmt.ext)")
                try await Self.downloadFormat(singleFmt, to: dest, maxHeight: item.quality.maxHeight) { d, t in
                    tracker.update(isVideo: singleFmt.hasVideo, done: d, total: t)
                }
                if singleFmt.hasVideo {
                    vPath = dest
                } else {
                    aPath = dest
                }
            }

            try Task.checkCancellation()

            updateItem(id) { $0.status = .merging }
            liveStats[id] = DownloadLiveStats(stage: (vPath != nil && aPath != nil) ? "Merging video & audio…" : "Finalizing…")

            let artwork = await Self.fetchArtwork(urlString: resolvedThumb)
            try Task.checkCancellation()
            let metadata = MP4Muxer.Metadata(
                title: resolvedTitle,
                artist: resolvedAuthor ?? "",
                date: media.uploadDate,
                sourceURL: media.url,
                artwork: artwork
            )

            if let vPath, let aPath, ext == "mp4" {
                try await MP4Muxer.muxMP4(videoURL: vPath, audioURL: aPath, outputURL: outputURL, metadata: metadata)
            } else if let singlePath = vPath ?? aPath {
                if ext == "mp4" || ext == "m4a" {
                    do {
                        try await MP4Muxer.tagMP4(inputURL: singlePath, outputURL: outputURL, metadata: metadata)
                    } catch {
                        try Task.checkCancellation()
                        try? FileManager.default.removeItem(at: outputURL)
                        try FileManager.default.moveItem(at: singlePath, to: outputURL)
                    }
                } else {
                    try? FileManager.default.removeItem(at: outputURL)
                    try FileManager.default.moveItem(at: singlePath, to: outputURL)
                }
            }

            try Task.checkCancellation()
            MP4Muxer.setMacWhereFrom(fileURL: outputURL, sourceURL: media.url)
            cleanupWorkDir(for: id)

            let finalSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
            updateItem(id) {
                $0.status = .completed
                $0.filePath = outputURL.path
                $0.fileSize = finalSize
                if finalSize > 0 {
                    $0.downloadedBytes = finalSize
                    $0.totalBytes = finalSize
                }
                $0.completedAt = nowMilliseconds()
                $0.errorMessage = nil
            }
            unfinishedOutput = nil
            liveStats.removeValue(forKey: id)
        } catch is CancellationError {
            let lastStats = liveStats.removeValue(forKey: id)
            if pauseRequested.contains(id) {
                updateItem(id) {
                    $0.status = .paused
                    if let lastStats {
                        $0.downloadedBytes = max($0.downloadedBytes, lastStats.downloadedBytes)
                        if lastStats.totalBytes > 0 { $0.totalBytes = lastStats.totalBytes }
                    }
                }
            } else {
                cleanupWorkDir(for: id)
                if cancelRequested.contains(id) {
                    updateItem(id) { $0.status = .cancelled }
                } else {
                    updateItem(id) { $0.status = .paused }
                }
            }
        } catch {
            let lastStats = liveStats.removeValue(forKey: id)
            updateItem(id) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
                if let lastStats {
                    $0.downloadedBytes = max($0.downloadedBytes, lastStats.downloadedBytes)
                    if lastStats.totalBytes > 0 { $0.totalBytes = lastStats.totalBytes }
                }
            }
        }
    }

    @concurrent
    private static func downloadFormat(
        _ format: MediaFormat,
        to destURL: URL,
        maxHeight: Int,
        onProgress: @escaping @Sendable (_ downloaded: Int64, _ total: Int64) -> Void
    ) async throws {
        let itagURL = destURL.appendingPathExtension("itag")
        if let existingSize = completedTrackSize(at: destURL, itagURL: itagURL, format: format) {
            onProgress(existingSize, existingSize)
            return
        }

        guard let url = URL(string: format.url) else {
            throw YouTubeError("Invalid media stream URL.")
        }
        if format.protocolName == "hls" {
            try await HLSDownloader.downloadVOD(
                playlistURL: url,
                destURL: destURL,
                maxHeight: maxHeight,
                headers: format.headers,
                connections: 4,
                onProgress: onProgress
            )
        } else {
            try await RangeDownloader.download(
                url: url,
                destURL: destURL,
                headers: format.headers,
                connections: 6,
                expectedSize: format.filesize,
                onProgress: onProgress
            )
        }
        try? format.id.write(to: itagURL, atomically: true, encoding: .utf8)
    }

    nonisolated private static func completedTrackSize(at destURL: URL, itagURL: URL, format: MediaFormat) -> Int64? {
        guard FileManager.default.fileExists(atPath: destURL.path),
              let savedItag = try? String(contentsOf: itagURL, encoding: .utf8),
              savedItag == format.id,
              let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64),
              size > 0
        else { return nil }
        if format.filesize > 0 && size != format.filesize {
            return nil
        }
        return size
    }

    @concurrent
    private static func fetchArtwork(urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        let req = URLRequest(url: url, timeoutInterval: 10)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        return data
    }

    // MARK: - Helpers

    private func updateItem(_ id: String, save: Bool = true, _ mutate: (inout DownloadItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[idx])
        revision += 1
        if save { scheduleSave() }
    }

    private func workDirectory(for id: String) -> URL {
        AppPaths.partialDownloads.appending(path: id, directoryHint: .isDirectory)
    }

    private func cleanupWorkDir(for id: String) {
        let dir = workDirectory(for: id)
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files {
                RangeDownloader.cleanupPartialFiles(for: f)
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private func uniqueOutputURL(in dir: URL, title: String, ext: String) -> URL {
        let base = sanitizeFilename(title)
        var candidate = dir.appending(path: "\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appending(path: "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\0\n\r\t")
        let cleaned = name.components(separatedBy: invalid).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let fallback = cleaned.isEmpty ? "YouTube Video" : cleaned
        return String(fallback.prefix(160))
    }
}

private nonisolated final class ProgressTracker: Sendable {
    private struct State: Sendable {
        var lastEmit: Date = .distantPast
        var vDone: Int64 = 0
        var vTotal: Int64
        var aDone: Int64 = 0
        var aTotal: Int64
    }

    private let startTime = Date()
    private let state: Mutex<State>
    private let onUpdate: @Sendable (Int64, Int64, Int64, Int64?) -> Void

    init(
        initialVideoTotal: Int64,
        initialAudioTotal: Int64,
        onUpdate: @escaping @Sendable (Int64, Int64, Int64, Int64?) -> Void
    ) {
        self.state = Mutex(State(vTotal: initialVideoTotal, aTotal: initialAudioTotal))
        self.onUpdate = onUpdate
    }

    func update(isVideo: Bool, done: Int64, total: Int64) {
        let snapshot = state.withLock { s -> (Int64, Int64)? in
            if isVideo {
                s.vDone = done
                if total > 0 { s.vTotal = total }
            } else {
                s.aDone = done
                if total > 0 { s.aTotal = total }
            }
            let now = Date()
            let combinedDone = s.vDone + s.aDone
            let combinedTotal = s.vTotal + s.aTotal
            guard now.timeIntervalSince(s.lastEmit) >= 0.2 || (combinedTotal > 0 && combinedDone >= combinedTotal) else {
                return nil
            }
            s.lastEmit = now
            return (combinedDone, combinedTotal)
        }
        guard let (combinedDone, combinedTotal) = snapshot else { return }
        let elapsed = max(0.25, Date().timeIntervalSince(startTime))
        let speed = Int64(Double(combinedDone) / elapsed)
        let eta: Int64? = (speed > 0 && combinedTotal > combinedDone) ? (combinedTotal - combinedDone) / speed : nil
        onUpdate(combinedDone, combinedTotal, speed, eta)
    }
}
