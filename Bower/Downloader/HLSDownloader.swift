import CommonCrypto
import Foundation
import Synchronization

nonisolated enum HLSDownloader {
    struct Segment: Sendable {
        var seq: Int64
        var url: URL
        var duration: Double
        var byteRange: String?
        var initURL: URL?
        var keyURL: URL?
        var keyIV: Data?
    }

    struct Variant: Sendable {
        var url: URL
        var bandwidth: Int64
        var width: Int
        var height: Int
        var audioGroupID: String?
    }

    struct Playlist: Sendable {
        var isMaster: Bool
        var isLive: Bool
        var segments: [Segment]
        var variants: [Variant]
        var audioGroups: [String: URL] = [:]
    }

    @concurrent
    static func downloadVOD(
        playlistURL: URL,
        destURL: URL,
        maxHeight: Int = 0,
        headers: [String: String] = [:],
        connections: Int = 4,
        onProgress: @escaping @Sendable (_ downloaded: Int64, _ total: Int64) -> Void
    ) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let playlist = try await fetchAndParse(session: session, url: playlistURL, headers: headers)
        if playlist.isMaster {
            guard !playlist.variants.isEmpty else {
                throw YouTubeError("HLS master playlist contains no variants.")
            }
            let sorted = playlist.variants.sorted { a, b in
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
                return a.bandwidth > b.bandwidth
            }
            let chosen = sorted[0]
            if let groupID = chosen.audioGroupID, let audioURL = playlist.audioGroups[groupID] {
                let tmpDir = FileManager.default.temporaryDirectory.appending(path: "bower-hls-mux-\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tmpDir) }

                let videoDest = tmpDir.appending(path: "video.mp4")
                let audioDest = tmpDir.appending(path: "audio.m4a")
                let combinedProgress = Mutex<(vDone: Int64, vTotal: Int64, aDone: Int64, aTotal: Int64)>((0, 0, 0, 0))
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await downloadVOD(playlistURL: chosen.url, destURL: videoDest, maxHeight: maxHeight, headers: headers, connections: connections) { d, t in
                            let snap = combinedProgress.withLock { s -> (Int64, Int64) in
                                s.vDone = d
                                if t > 0 { s.vTotal = t }
                                return (s.vDone + s.aDone, s.vTotal + s.aTotal)
                            }
                            onProgress(snap.0, snap.1)
                        }
                    }
                    group.addTask {
                        try await downloadVOD(playlistURL: audioURL, destURL: audioDest, maxHeight: 0, headers: headers, connections: max(1, connections / 2)) { d, t in
                            let snap = combinedProgress.withLock { s -> (Int64, Int64) in
                                s.aDone = d
                                if t > 0 { s.aTotal = t }
                                return (s.vDone + s.aDone, s.vTotal + s.aTotal)
                            }
                            onProgress(snap.0, snap.1)
                        }
                    }
                    try await group.waitForAll()
                }
                try await MP4Muxer.muxMP4(videoURL: videoDest, audioURL: audioDest, outputURL: destURL, metadata: MP4Muxer.Metadata())
                return
            }

            try await downloadVOD(
                playlistURL: chosen.url,
                destURL: destURL,
                maxHeight: maxHeight,
                headers: headers,
                connections: connections,
                onProgress: onProgress
            )
            return
        }

        let segments = playlist.segments
        guard !segments.isEmpty else {
            throw YouTubeError("HLS playlist contains no segments.")
        }

        let tmpDir = FileManager.default.temporaryDirectory.appending(path: "bower-hls-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var initCache: [URL: Data] = [:]
        for seg in segments {
            if let initURL = seg.initURL, initCache[initURL] == nil {
                initCache[initURL] = try await fetchBytes(session: session, url: initURL, byteRange: nil, headers: headers)
            }
        }

        let keyCache = KeyCache()
        let progressState = Mutex<(bytes: Int64, completed: Int64)>((0, 0))
        let totalSegments = Int64(segments.count)
        let maxWorkers = max(1, min(connections, segments.count))

        try await withThrowingTaskGroup(of: Void.self) { group in
            var nextIdx = 0
            func addNext() {
                guard nextIdx < segments.count else { return }
                let idx = nextIdx
                let seg = segments[idx]
                nextIdx += 1
                group.addTask {
                    let data = try await fetchSegmentWithRetry(session: session, segment: seg, headers: headers, keyCache: keyCache)
                    let segFile = tmpDir.appending(path: String(format: "seg_%06d.bin", idx))
                    try data.write(to: segFile, options: .atomic)
                    let (bytes, completed) = progressState.withLock { state -> (Int64, Int64) in
                        state.bytes += Int64(data.count)
                        state.completed += 1
                        return state
                    }
                    let estTotal = completed > 0 ? (bytes * totalSegments / completed) : 0
                    onProgress(bytes, estTotal)
                }
            }

            for _ in 0..<maxWorkers {
                addNext()
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                addNext()
            }
        }

        let partURL = destURL.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: partURL)
        defer { try? out.close() }
        var lastInitURL: URL?
        for (idx, seg) in segments.enumerated() {
            try Task.checkCancellation()
            if let initURL = seg.initURL, initURL != lastInitURL, let initData = initCache[initURL], !initData.isEmpty {
                try out.write(contentsOf: initData)
                lastInitURL = initURL
            }
            let segFile = tmpDir.appending(path: String(format: "seg_%06d.bin", idx))
            let data = try Data(contentsOf: segFile)
            try out.write(contentsOf: data)
        }
        try out.close()
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: partURL, to: destURL)
    }

    // MARK: - Parsing

    private static func fetchAndParse(session: URLSession, url: URL, headers: [String: String]) async throws -> Playlist {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw YouTubeError("HTTP \(http.statusCode) fetching HLS playlist.")
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw YouTubeError("Invalid HLS playlist encoding.")
        }
        let baseURL = resp.url ?? url
        return try parse(body: body, baseURL: baseURL)
    }

    private static func parse(body: String, baseURL: URL) throws -> Playlist {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }

        if body.contains("#EXT-X-STREAM-INF") {
            var variants: [Variant] = []
            var audioGroups: [String: URL] = [:]
            for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
                if extractAttr("TYPE", in: line)?.uppercased() == "AUDIO",
                   let groupID = extractQuotedAttr("GROUP-ID", in: line),
                   let uri = extractQuotedAttr("URI", in: line),
                   let resolved = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                    let isDefault = extractAttr("DEFAULT", in: line)?.uppercased() == "YES"
                    if audioGroups[groupID] == nil || isDefault {
                        audioGroups[groupID] = resolved
                    }
                }
            }
            var i = 0
            while i < lines.count {
                let line = lines[i]
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    let bw = extractIntAttr("BANDWIDTH=", in: line) ?? 0
                    let (w, h) = extractResolution(in: line)
                    let audioGroupID = extractQuotedAttr("AUDIO", in: line)
                    var j = i + 1
                    while j < lines.count {
                        let cand = lines[j]
                        if !cand.isEmpty, !cand.hasPrefix("#") {
                            if let resolved = URL(string: cand, relativeTo: baseURL)?.absoluteURL {
                                variants.append(Variant(url: resolved, bandwidth: Int64(bw), width: w, height: h, audioGroupID: audioGroupID))
                            }
                            i = j
                            break
                        }
                        j += 1
                    }
                }
                i += 1
            }
            return Playlist(isMaster: true, isLive: false, segments: [], variants: variants, audioGroups: audioGroups)
        }

        let isLive = !body.contains("#EXT-X-ENDLIST")
        var segments: [Segment] = []
        var seq: Int64 = 0
        var curDur: Double = 0
        var curByteRange: String?
        var curInit: URL?
        var curKeyURL: URL?
        var curKeyIV: Data?

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                seq = Int64(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = extractQuotedAttr("URI", in: line) {
                    curInit = URL(string: uri, relativeTo: baseURL)?.absoluteURL
                }
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = extractMethod(in: line)
                if method == "NONE" || method.isEmpty {
                    curKeyURL = nil
                    curKeyIV = nil
                } else if method == "AES-128" {
                    if let uri = extractQuotedAttr("URI", in: line) {
                        curKeyURL = URL(string: uri, relativeTo: baseURL)?.absoluteURL
                    }
                    curKeyIV = extractIV(in: line)
                } else {
                    throw YouTubeError("Unsupported HLS encryption method: \(method).")
                }
            } else if line.hasPrefix("#EXTINF:") {
                let rest = line.dropFirst("#EXTINF:".count)
                let num = rest.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
                curDur = Double(num.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                curByteRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if !line.hasPrefix("#"), let segURL = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                var iv = curKeyIV
                if curKeyURL != nil, iv == nil {
                    var bytes = Data(count: 16)
                    var bigSeq = seq.bigEndian
                    bytes.replaceSubrange(8..<16, with: Data(bytes: &bigSeq, count: 8))
                    iv = bytes
                }
                segments.append(Segment(
                    seq: seq,
                    url: segURL,
                    duration: curDur,
                    byteRange: curByteRange,
                    initURL: curInit,
                    keyURL: curKeyURL,
                    keyIV: iv
                ))
                seq += 1
                curDur = 0
                curByteRange = nil
            }
        }
        return Playlist(isMaster: false, isLive: isLive, segments: segments, variants: [])
    }

    // MARK: - Segment Fetching & Decryption

    private final class KeyCache: Sendable {
        let storage = Mutex<[URL: Data]>([:])
    }

    private static func fetchSegmentWithRetry(
        session: URLSession,
        segment: Segment,
        headers: [String: String],
        keyCache: KeyCache
    ) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                var data = try await fetchBytes(session: session, url: segment.url, byteRange: segment.byteRange, headers: headers)
                if let keyURL = segment.keyURL {
                    let key: Data
                    if let cached = keyCache.storage.withLock({ $0[keyURL] }) {
                        key = cached
                    } else {
                        key = try await fetchBytes(session: session, url: keyURL, byteRange: nil, headers: headers)
                        keyCache.storage.withLock { $0[keyURL] = key }
                    }
                    if let iv = segment.keyIV {
                        data = try decryptAES128CBC(data: data, key: key, iv: iv)
                    }
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(350 * (attempt + 1)))
            }
        }
        throw lastError ?? YouTubeError("Failed to download HLS segment.")
    }

    private static func fetchBytes(session: URLSession, url: URL, byteRange: String?, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let byteRange, !byteRange.isEmpty {
            let parts = byteRange.split(separator: "@")
            if parts.count == 2, let len = Int64(parts[0]), let off = Int64(parts[1]) {
                req.setValue("bytes=\(off)-\(off + len - 1)", forHTTPHeaderField: "Range")
            }
        }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw YouTubeError("HTTP \(http.statusCode) fetching HLS segment.")
        }
        return data
    }

    private static func decryptAES128CBC(data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw YouTubeError("Invalid AES-128 key or IV size.")
        }
        var outLength = 0
        let outCapacity = data.count + kCCBlockSizeAES128
        var decrypted = Data(count: outCapacity)
        let status = decrypted.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, data.count,
                            outPtr.baseAddress, outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw YouTubeError("AES-128 decryption failed (status \(status)).")
        }
        decrypted.removeSubrange(outLength..<decrypted.count)
        return decrypted
    }

    // MARK: - Attribute Parsers

    private static func extractIntAttr(_ prefix: String, in line: String) -> Int? {
        guard let r = line.range(of: prefix) else { return nil }
        let rest = line[r.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func extractResolution(in line: String) -> (Int, Int) {
        guard let r = line.range(of: "RESOLUTION=") else { return (0, 0) }
        let rest = line[r.upperBound...]
        let token = rest.prefix { $0.isNumber || $0 == "x" }
        let parts = token.split(separator: "x")
        if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
            return (w, h)
        }
        return (0, 0)
    }

    private static func extractQuotedAttr(_ name: String, in line: String) -> String? {
        guard let r = line.range(of: "\(name)=\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func extractAttr(_ name: String, in line: String) -> String? {
        guard let r = line.range(of: "\(name)=") else { return nil }
        let rest = line[r.upperBound...]
        if rest.first == "\"" {
            return extractQuotedAttr(name, in: line)
        }
        return String(rest.prefix { $0 != "," }).trimmingCharacters(in: .whitespaces)
    }

    private static func extractMethod(in line: String) -> String {
        guard let r = line.range(of: "METHOD=") else { return "" }
        let rest = line[r.upperBound...]
        let val = rest.prefix { $0 != "," }
        return val.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private static func extractIV(in line: String) -> Data? {
        guard let r = line.range(of: "IV=0x", options: .caseInsensitive) else { return nil }
        let hexStr = String(line[r.upperBound...].prefix { $0.isHexDigit })
        guard !hexStr.isEmpty else { return nil }
        let padded = String(repeating: "0", count: max(0, 32 - hexStr.count)) + hexStr
        var data = Data(capacity: 16)
        var idx = padded.startIndex
        while idx < padded.endIndex {
            let next = padded.index(idx, offsetBy: 2, limitedBy: padded.endIndex) ?? padded.endIndex
            if let byte = UInt8(padded[idx..<next], radix: 16) {
                data.append(byte)
            }
            idx = next
        }
        return data.count == 16 ? data : nil
    }
}
