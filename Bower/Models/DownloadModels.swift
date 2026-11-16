import Foundation

nonisolated enum DownloadQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case best
    case p2160
    case p1440
    case p1080
    case p720
    case p480
    case p360
    case audioOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: "Best Available"
        case .p2160: "4K (2160p)"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .p360: "360p"
        case .audioOnly: "Audio Only (M4A)"
        }
    }

    var shortLabel: String {
        switch self {
        case .best: "Best"
        case .p2160: "2160p"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .p360: "360p"
        case .audioOnly: "Audio"
        }
    }

    var maxHeight: Int {
        switch self {
        case .best, .audioOnly: 0
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        case .p360: 360
        }
    }
}

nonisolated enum DownloadStatus: String, Codable, Sendable {
    case queued
    case extracting
    case downloading
    case merging
    case paused
    case completed
    case failed
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .extracting, .downloading, .merging: true
        default: false
        }
    }
}

nonisolated struct DownloadItem: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var videoID: String
    var title: String
    var author: String?
    var thumbnail: String
    var duration: String
    var watchURL: String
    var quality: DownloadQuality
    var resolvedQualityLabel: String?
    var ext: String
    var filePath: String?
    var status: DownloadStatus
    var downloadedBytes: Int64
    var totalBytes: Int64
    var fileSize: Int64
    var errorMessage: String?
    var createdAt: Double
    var completedAt: Double?

    var video: Video {
        Video(id: videoID, title: title, thumbnail: thumbnail, duration: duration, sourceTitle: author)
    }

    var fileURL: URL? {
        filePath.map { URL(fileURLWithPath: $0) }
    }

    var fileExists: Bool {
        guard let path = filePath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var fraction: Double {
        if status == .completed { return 1 }
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }
}

nonisolated struct DownloadLiveStats: Sendable {
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speedBytesPerSec: Int64 = 0
    var etaSeconds: Int64?
    var stage: String = ""

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }
}

nonisolated struct MediaFormat: Sendable {
    var id: String
    var url: String
    var ext: String
    var protocolName: String // "http" or "hls"
    var hasVideo: Bool
    var hasAudio: Bool
    var width: Int
    var height: Int
    var fps: Double
    var vcodec: String
    var acodec: String
    var bitrate: Int64
    var filesize: Int64
    var qualityLabel: String
    var headers: [String: String]
}

nonisolated struct ExtractedMedia: Sendable {
    var videoID: String
    var url: String
    var title: String
    var author: String
    var uploadDate: String // YYYYMMDD
    var durationSeconds: Double
    var thumbnailURL: String
    var isLive: Bool
    var formats: [MediaFormat]
}

nonisolated struct SelectedMediaFormats: Sendable {
    var video: MediaFormat?
    var audio: MediaFormat?
}
