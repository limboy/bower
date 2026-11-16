import CryptoKit
import Foundation

nonisolated enum YouTubeStreamExtractor {
    private struct ClientProfile: Sendable {
        let name: String
        let clientName: String
        let clientVersion: String
        let userAgent: String
        let osName: String?
        let osVersion: String?
        let deviceMake: String?
        let deviceModel: String?
        let clientID: String
    }

    private static let clientProfiles: [ClientProfile] = [
        ClientProfile(
            name: "VISIONOS",
            clientName: "VISIONOS",
            clientVersion: "0.1",
            userAgent: "Mozilla/5.0 (Macintosh; Apple Vision Pro) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            osName: "visionOS",
            osVersion: "1.3.21O771",
            deviceMake: "Apple",
            deviceModel: "RealityDevice14,1",
            clientID: "101"
        ),
        ClientProfile(
            name: "ANDROID_VR",
            clientName: "ANDROID_VR",
            clientVersion: "1.62.27",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            osName: "Android",
            osVersion: "12L",
            deviceMake: "Oculus",
            deviceModel: "Quest 3",
            clientID: "28"
        ),
        ClientProfile(
            name: "IOS",
            clientName: "IOS",
            clientVersion: "20.10.4",
            userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            osName: "iPhone",
            osVersion: "18.3.2.22D82",
            deviceMake: "Apple",
            deviceModel: "iPhone16,2",
            clientID: "5"
        ),
        ClientProfile(
            name: "ANDROID",
            clientName: "ANDROID",
            clientVersion: "20.10.38",
            userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip",
            osName: "Android",
            osVersion: "14",
            deviceMake: nil,
            deviceModel: nil,
            clientID: "3"
        ),
    ]

    @concurrent
    static func extract(videoID: String) async throws -> ExtractedMedia {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (visitorData, htmlResponse) = await fetchWatchPage(session: session, videoID: videoID)

        var playerResponse: [String: Any]?
        var usedUserAgent = InnerTubeClient.userAgent
        var lastError: String?

        for profile in clientProfiles {
            do {
                let json = try await callInnerTubePlayer(
                    session: session,
                    videoID: videoID,
                    profile: profile,
                    visitorData: visitorData,
                    useUserCookie: false
                )
                if isPlayableWithDirectStreams(json) {
                    playerResponse = json
                    usedUserAgent = profile.userAgent
                    break
                }
                if let reason = playabilityReason(json) {
                    lastError = reason
                }
            } catch {
                lastError = error.localizedDescription
            }
        }

        // If unauthenticated clients failed and user saved a cookie, retry TV embedded / IOS with user cookie.
        if playerResponse == nil, CookieStore.shared.hasCookie {
            for profile in clientProfiles.reversed() {
                do {
                    let json = try await callInnerTubePlayer(
                        session: session,
                        videoID: videoID,
                        profile: profile,
                        visitorData: visitorData,
                        useUserCookie: true
                    )
                    if isPlayableWithDirectStreams(json) {
                        playerResponse = json
                        usedUserAgent = profile.userAgent
                        break
                    }
                    if let reason = playabilityReason(json) {
                        lastError = reason
                    }
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }

        if playerResponse == nil, let htmlResponse, isPlayableWithDirectStreams(htmlResponse) {
            playerResponse = htmlResponse
            usedUserAgent = InnerTubeClient.userAgent
        }

        guard let pr = playerResponse else {
            throw YouTubeError(lastError ?? "No downloadable video streams were returned by YouTube.")
        }

        let details = pr["videoDetails"] as? [String: Any] ?? [:]
        let title = (details["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "YouTube Video \(videoID)"
        let author = details["author"] as? String ?? ""
        let lengthSeconds = Double(details["lengthSeconds"] as? String ?? "") ?? 0
        let isLiveContent = details["isLiveContent"] as? Bool ?? false

        let streamingData = pr["streamingData"] as? [String: Any] ?? [:]
        let hlsManifestURL = streamingData["hlsManifestUrl"] as? String ?? ""
        let isLive = isLiveContent && !hlsManifestURL.isEmpty && lengthSeconds == 0

        var thumbnailURL = InnerTubeParser.thumbnail(for: videoID)
        if let thumbObj = details["thumbnail"] as? [String: Any],
           let thumbs = thumbObj["thumbnails"] as? [[String: Any]],
           let bestThumb = thumbs.last?["url"] as? String, !bestThumb.isEmpty {
            thumbnailURL = bestThumb
        }

        var uploadDate = ""
        if let microformat = pr["microformat"] as? [String: Any],
           let renderer = microformat["playerMicroformatRenderer"] as? [String: Any],
           let pub = renderer["publishDate"] as? String {
            uploadDate = pub.replacingOccurrences(of: "-", with: "")
        }

        var formats: [MediaFormat] = []
        let rawAdaptive = streamingData["adaptiveFormats"] as? [[String: Any]] ?? []
        let rawProgressive = streamingData["formats"] as? [[String: Any]] ?? []

        for raw in rawAdaptive {
            if let fmt = parseFormat(raw, progressive: false, userAgent: usedUserAgent) {
                formats.append(fmt)
            }
        }
        for raw in rawProgressive {
            if let fmt = parseFormat(raw, progressive: true, userAgent: usedUserAgent) {
                formats.append(fmt)
            }
        }
        if !hlsManifestURL.isEmpty {
            formats.append(MediaFormat(
                id: "hls",
                url: hlsManifestURL,
                ext: "mp4",
                protocolName: "hls",
                hasVideo: true,
                hasAudio: true,
                width: 0,
                height: 0,
                fps: 0,
                vcodec: "",
                acodec: "",
                bitrate: 0,
                filesize: 0,
                qualityLabel: "HLS",
                headers: ["User-Agent": usedUserAgent]
            ))
        }

        guard !formats.isEmpty else {
            throw YouTubeError("Streams require signature decryption or YouTube login cookies.")
        }

        return ExtractedMedia(
            videoID: videoID,
            url: "https://www.youtube.com/watch?v=\(videoID)",
            title: title,
            author: author,
            uploadDate: uploadDate,
            durationSeconds: lengthSeconds,
            thumbnailURL: thumbnailURL,
            isLive: isLive,
            formats: formats
        )
    }

    static func selectFormats(from media: ExtractedMedia, quality: DownloadQuality) throws -> SelectedMediaFormats {
        guard !media.formats.isEmpty else {
            throw YouTubeError("No downloadable formats available.")
        }

        if quality == .audioOnly {
            let audioOnly = media.formats.filter { !$0.hasVideo && $0.hasAudio }
            let muxed = media.formats.filter { $0.hasAudio }
            let pool = audioOnly.isEmpty ? (muxed.isEmpty ? media.formats : muxed) : audioOnly
            let sorted = pool.sorted { a, b in
                let aMP4 = a.ext == "m4a" || a.acodec == "aac"
                let bMP4 = b.ext == "m4a" || b.acodec == "aac"
                if aMP4 != bMP4 { return aMP4 }
                return a.bitrate > b.bitrate
            }
            return SelectedMediaFormats(video: nil, audio: sorted[0])
        }

        let maxHeight = quality.maxHeight

        // Prefer MP4/M4A formats so our pure-Swift MP4 muxer can combine them natively without FFmpeg.
        let mp4Video = media.formats.filter { $0.hasVideo && !$0.hasAudio && $0.ext == "mp4" && $0.protocolName == "http" }
        let m4aAudio = media.formats.filter { !$0.hasVideo && $0.hasAudio && ($0.ext == "m4a" || $0.ext == "mp4") && $0.protocolName == "http" }
        let mp4Muxed = media.formats.filter { $0.hasVideo && $0.hasAudio && $0.ext == "mp4" && $0.protocolName == "http" }

        let allVideo = mp4Video.isEmpty ? media.formats.filter { $0.hasVideo && !$0.hasAudio && $0.protocolName == "http" } : mp4Video
        let allAudio = m4aAudio.isEmpty ? media.formats.filter { !$0.hasVideo && $0.hasAudio && $0.protocolName == "http" } : m4aAudio
        let allMuxed = mp4Muxed.isEmpty ? media.formats.filter { $0.hasVideo && $0.hasAudio } : mp4Muxed

        func sortVideo(_ list: [MediaFormat]) -> [MediaFormat] {
            list.sorted { a, b in
                if maxHeight > 0 {
                    let inA = a.height > 0 && a.height <= maxHeight
                    let inB = b.height > 0 && b.height <= maxHeight
                    if inA != inB { return inA }
                }
                if a.height != b.height {
                    if maxHeight > 0 && a.height > maxHeight && b.height > maxHeight {
                        return a.height < b.height
                    }
                    return a.height > b.height
                }
                let aH264 = a.vcodec == "h264"
                let bH264 = b.vcodec == "h264"
                if aH264 != bH264 { return aH264 }
                if a.fps != b.fps { return a.fps > b.fps }
                return a.bitrate > b.bitrate
            }
        }

        let sortedVideo = sortVideo(allVideo)
        let sortedMuxed = sortVideo(allMuxed)
        let sortedAudio = allAudio.sorted { a, b in
            let aAAC = a.acodec == "aac" || a.ext == "m4a"
            let bAAC = b.acodec == "aac" || b.ext == "m4a"
            if aAAC != bAAC { return aAAC }
            return a.bitrate > b.bitrate
        }

        if let bestV = sortedVideo.first, let bestA = sortedAudio.first,
           bestV.ext == "mp4", (bestA.ext == "m4a" || bestA.ext == "mp4") {
            if let muxed = sortedMuxed.first,
               muxed.protocolName == "http",
               muxed.height >= bestV.height,
               (maxHeight == 0 || muxed.height <= maxHeight),
               (muxed.vcodec == "h264" || muxed.vcodec.isEmpty) {
                return SelectedMediaFormats(video: muxed, audio: nil)
            }
            return SelectedMediaFormats(video: bestV, audio: bestA)
        }

        if let muxed = sortedMuxed.first {
            return SelectedMediaFormats(video: muxed, audio: nil)
        }
        if let v = sortedVideo.first {
            return SelectedMediaFormats(video: v, audio: nil)
        }
        if let a = sortedAudio.first {
            return SelectedMediaFormats(video: nil, audio: a)
        }
        throw YouTubeError("No compatible MP4/HLS formats found.")
    }

    // MARK: - Private Helpers

    private static func fetchWatchPage(session: URLSession, videoID: String) async -> (visitorData: String?, playerResponse: [String: Any]?) {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)&hl=en") else {
            return (nil, nil)
        }
        var req = URLRequest(url: url)
        req.setValue(InnerTubeClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if CookieStore.shared.hasCookie {
            req.setValue(CookieStore.shared.cookie, forHTTPHeaderField: "Cookie")
        }

        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8)
        else {
            return (nil, nil)
        }

        var visitorData: String?
        if let regex = try? NSRegularExpression(pattern: #""visitorData"\s*:\s*"([^"]+)""#),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            visitorData = String(html[range])
        }

        var playerResponse: [String: Any]?
        if let jsonString = extractJSONObject(after: "ytInitialPlayerResponse", in: html),
           let jsonData = jsonString.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            playerResponse = parsed
        }
        return (visitorData, playerResponse)
    }

    private static func extractJSONObject(after marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        guard let braceStart = text[markerRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = braceStart
        while idx < text.endIndex {
            let ch = text[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[braceStart...idx])
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private static func callInnerTubePlayer(
        session: URLSession,
        videoID: String,
        profile: ClientProfile,
        visitorData: String?,
        useUserCookie: Bool
    ) async throws -> [String: Any] {
        var clientObj: [String: Any] = [
            "clientName": profile.clientName,
            "clientVersion": profile.clientVersion,
            "hl": "en",
            "gl": "US",
        ]
        if let osName = profile.osName { clientObj["osName"] = osName }
        if let osVersion = profile.osVersion { clientObj["osVersion"] = osVersion }
        if let deviceMake = profile.deviceMake { clientObj["deviceMake"] = deviceMake }
        if let deviceModel = profile.deviceModel { clientObj["deviceModel"] = deviceModel }
        if let visitorData, !visitorData.isEmpty {
            clientObj["visitorData"] = visitorData
        }

        let payload: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": clientObj,
                "thirdParty": [
                    "embedUrl": "https://www.youtube.com/",
                ],
            ],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]

        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(profile.clientID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(profile.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if let visitorData, !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        if useUserCookie, CookieStore.shared.hasCookie {
            request.setValue(CookieStore.shared.cookie, forHTTPHeaderField: "Cookie")
            if let sapisid = CookieStore.shared.sapisid {
                let ts = Int(Date().timeIntervalSince1970)
                let digest = Insecure.SHA1.hash(data: Data("\(ts) \(sapisid) https://www.youtube.com".utf8))
                    .map { String(format: "%02x", $0) }.joined()
                request.setValue("SAPISIDHASH \(ts)_\(digest)", forHTTPHeaderField: "Authorization")
                request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            }
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YouTubeError("YouTube returned HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeError("Invalid response from YouTube")
        }
        return json
    }

    private static func isPlayableWithDirectStreams(_ json: [String: Any]) -> Bool {
        let status = (json["playabilityStatus"] as? [String: Any])?["status"] as? String
        guard status == "OK" else { return false }
        let sd = json["streamingData"] as? [String: Any] ?? [:]
        let adaptive = sd["adaptiveFormats"] as? [[String: Any]] ?? []
        let formats = sd["formats"] as? [[String: Any]] ?? []
        let hasDirectURL = (adaptive + formats).contains { ($0["url"] as? String)?.isEmpty == false }
        let hasHLS = (sd["hlsManifestUrl"] as? String)?.isEmpty == false
        return hasDirectURL || hasHLS
    }

    private static func playabilityReason(_ json: [String: Any]) -> String? {
        guard let ps = json["playabilityStatus"] as? [String: Any] else { return nil }
        let status = ps["status"] as? String ?? ""
        let reason = ps["reason"] as? String ?? ""
        if !reason.isEmpty { return "\(status): \(reason)" }
        return status.isEmpty ? nil : status
    }

    private static func parseFormat(_ raw: [String: Any], progressive: Bool, userAgent: String) -> MediaFormat? {
        guard let url = raw["url"] as? String, !url.isEmpty else { return nil }
        let itag = raw["itag"] as? Int ?? 0
        let mimeType = raw["mimeType"] as? String ?? ""
        let (mime, vcodec, acodec) = parseMimeType(mimeType)

        let width = raw["width"] as? Int ?? 0
        let height = raw["height"] as? Int ?? 0
        let fps = Double(raw["fps"] as? Int ?? 0)
        let bitrate = (raw["bitrate"] as? NSNumber)?.int64Value ?? 0
        let filesize = Int64(raw["contentLength"] as? String ?? "") ?? 0

        let hasVideo = width > 0 || mime.hasPrefix("video/")
        let hasAudio = progressive || mime.hasPrefix("audio/") || !acodec.isEmpty

        var ext = "mp4"
        if mime.contains("webm") {
            ext = "webm"
        } else if !hasVideo && mime.contains("mp4") {
            ext = "m4a"
        }

        var qualityLabel = raw["qualityLabel"] as? String ?? ""
        if qualityLabel.isEmpty {
            if hasVideo && height > 0 {
                qualityLabel = "\(height)p"
            } else if !hasVideo {
                qualityLabel = "Audio"
            }
        }

        return MediaFormat(
            id: String(itag),
            url: url,
            ext: ext,
            protocolName: "http",
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            width: width,
            height: height,
            fps: fps,
            vcodec: vcodec,
            acodec: acodec,
            bitrate: bitrate,
            filesize: filesize,
            qualityLabel: qualityLabel,
            headers: ["User-Agent": userAgent]
        )
    }

    private static func parseMimeType(_ mt: String) -> (mime: String, vcodec: String, acodec: String) {
        let parts = mt.split(separator: ";", maxSplits: 1)
        let mime = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        var vcodec = ""
        var acodec = ""

        if let startRange = mt.range(of: "codecs=\"") {
            let rest = mt[startRange.upperBound...]
            if let endQuote = rest.firstIndex(of: "\"") {
                let codecs = rest[..<endQuote].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for c in codecs {
                    if c.hasPrefix("avc1") {
                        vcodec = "h264"
                    } else if c.hasPrefix("vp9") || c.hasPrefix("vp09") {
                        vcodec = "vp9"
                    } else if c.hasPrefix("av01") {
                        vcodec = "av1"
                    } else if c.hasPrefix("mp4a") {
                        acodec = "aac"
                    } else if c.hasPrefix("opus") {
                        acodec = "opus"
                    } else if mime.hasPrefix("video/"), vcodec.isEmpty {
                        vcodec = c
                    } else if acodec.isEmpty {
                        acodec = c
                    }
                }
            }
        }
        return (mime, vcodec, acodec)
    }
}
