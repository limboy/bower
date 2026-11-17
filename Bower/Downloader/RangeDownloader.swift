import Darwin
import Foundation
import Synchronization

nonisolated enum RangeDownloader {
    // Large media ranges can be throttled by YouTube. Keep each request small
    // while retaining the existing worker partitions and resume checkpoints.
    private static let maxRangeRequestSize: Int64 = 1024 * 1024

    struct ChunkState: Codable, Sendable {
        var start: Int64
        var end: Int64
        var done: Int64
    }

    struct ResumeState: Codable, Sendable {
        var total: Int64
        var chunks: [ChunkState]
    }

    typealias ProgressHandler = @Sendable (_ downloaded: Int64, _ total: Int64) -> Void

    @concurrent
    static func download(
        url: URL,
        destURL: URL,
        headers: [String: String] = [:],
        connections: Int = 6,
        expectedSize: Int64 = 0,
        onProgress: @escaping ProgressHandler
    ) async throws {
        let delegate = StreamSessionDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        config.httpMaximumConnectionsPerHost = max(8, connections + 2)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (probedSize, acceptRanges) = try await probe(session: session, url: url, headers: headers)
        let totalSize = probedSize > 0 ? probedSize : expectedSize

        let conns = max(1, connections)
        if !acceptRanges || totalSize <= 512 * 1024 || conns == 1 {
            try await downloadStreamResume(
                session: session,
                delegate: delegate,
                url: url,
                destURL: destURL,
                totalSize: totalSize,
                acceptRanges: acceptRanges,
                headers: headers,
                onProgress: onProgress
            )
            return
        }

        try await downloadMultiChunk(
            session: session,
            delegate: delegate,
            url: url,
            destURL: destURL,
            totalSize: totalSize,
            connections: conns,
            headers: headers,
            onProgress: onProgress
        )
    }

    static func cleanupPartialFiles(for destURL: URL) {
        let partURL = destURL.appendingPathExtension("part")
        let stateURL = stateFileURL(for: destURL)
        try? FileManager.default.removeItem(at: partURL)
        try? FileManager.default.removeItem(at: stateURL)
    }

    // MARK: - Probe

    private static func probe(session: URLSession, url: URL, headers: [String: String]) async throws -> (size: Int64, acceptRanges: Bool) {
        var headReq = URLRequest(url: url)
        headReq.httpMethod = "HEAD"
        applyHeaders(headers, to: &headReq)
        if let (_, resp) = try? await session.data(for: headReq),
           let http = resp as? HTTPURLResponse,
           (200..<300).contains(http.statusCode) {
            let size = http.expectedContentLength
            let ar = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased()
            let acceptRanges = ar.contains("bytes") && size > 0
            if size > 0 {
                return (size, acceptRanges)
            }
        }

        // Fallback: GET Range: bytes=0-0
        var rangeReq = URLRequest(url: url)
        rangeReq.httpMethod = "GET"
        applyHeaders(headers, to: &rangeReq)
        rangeReq.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        let (bytes, resp) = try await session.bytes(for: rangeReq)
        bytes.task.cancel()
        guard let http = resp as? HTTPURLResponse else {
            throw YouTubeError("Invalid HTTP response while probing stream.")
        }
        if http.statusCode == 206 {
            if let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = cr.lastIndex(of: "/"),
               let total = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)),
               total > 0 {
                return (total, true)
            }
        }
        if http.statusCode >= 400 {
            throw YouTubeError("HTTP \(http.statusCode) probing stream.")
        }
        return (max(0, http.expectedContentLength), false)
    }

    // MARK: - Single Stream Resume

    private static func downloadStreamResume(
        session: URLSession,
        delegate: StreamSessionDelegate,
        url: URL,
        destURL: URL,
        totalSize: Int64,
        acceptRanges: Bool,
        headers: [String: String],
        onProgress: @escaping ProgressHandler
    ) async throws {
        let partURL = destURL.appendingPathExtension("part")
        var existing: Int64 = 0
        if acceptRanges,
           let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path),
           let sz = attrs[.size] as? Int64 {
            existing = sz
        }
        if totalSize > 0, existing == totalSize {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: partURL, to: destURL)
            onProgress(totalSize, totalSize)
            return
        }

        var req = URLRequest(url: url)
        applyHeaders(headers, to: &req)
        if acceptRanges, existing > 0 {
            req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        let (response, stream, cancelStream) = try await delegate.stream(session: session, request: req)
        if response.statusCode >= 400 {
            throw YouTubeError("HTTP \(response.statusCode) downloading stream.")
        }

        var finalTotal = totalSize
        let isPartial = response.statusCode == 206 && existing > 0
        if !isPartial {
            existing = 0
            if finalTotal <= 0, response.expectedContentLength > 0 {
                finalTotal = response.expectedContentLength
            }
        }

        if !FileManager.default.fileExists(atPath: partURL.path) || !isPartial {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        if isPartial {
            try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
        }

        var downloaded = existing
        try await withTaskCancellationHandler {
            for try await chunk in stream {
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
                downloaded += Int64(chunk.count)
                onProgress(downloaded, finalTotal)
            }
        } onCancel: {
            cancelStream()
        }
        try handle.close()
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: partURL, to: destURL)
    }

    // MARK: - Multi-Chunk Concurrent Range

    private static func downloadMultiChunk(
        session: URLSession,
        delegate: StreamSessionDelegate,
        url: URL,
        destURL: URL,
        totalSize: Int64,
        connections: Int,
        headers: [String: String],
        onProgress: @escaping ProgressHandler
    ) async throws {
        let partURL = destURL.appendingPathExtension("part")
        let stateURL = stateFileURL(for: destURL)
        let initialState = loadOrInitState(stateURL: stateURL, partURL: partURL, totalSize: totalSize, connections: connections)

        var fd = Darwin.open(partURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            if fd >= 0 { Darwin.close(fd) }
        }

        var st = Darwin.stat()
        if Darwin.fstat(fd, &st) == 0, st.st_size != totalSize {
            if Darwin.ftruncate(fd, totalSize) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        let activeFD = fd
        let stateLock = Mutex(initialState)
        let initialDone = initialState.chunks.reduce(Int64(0)) { $0 + $1.done }
        onProgress(initialDone, totalSize)

        let saveTask = Task { @Sendable in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                let snap = stateLock.withLock { $0 }
                writeResumeState(snap, to: stateURL)
            }
        }
        defer {
            saveTask.cancel()
            let snap = stateLock.withLock { $0 }
            writeResumeState(snap, to: stateURL)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for idx in initialState.chunks.indices {
                group.addTask { @Sendable in
                    var consecutiveFailures = 0
                    while true {
                        try Task.checkCancellation()
                        let chunk = stateLock.withLock { $0.chunks[idx] }
                        let curStart = chunk.start + chunk.done
                        if curStart > chunk.end { return }

                        do {
                            try await downloadChunkRange(
                                session: session,
                                delegate: delegate,
                                url: url,
                                headers: headers,
                                fd: activeFD,
                                start: curStart,
                                end: min(chunk.end, curStart + maxRangeRequestSize - 1)
                            ) { written in
                                let totalDone = stateLock.withLock { state -> Int64 in
                                    state.chunks[idx].done += Int64(written)
                                    return state.chunks.reduce(0) { $0 + $1.done }
                                }
                                onProgress(totalDone, totalSize)
                            }
                            consecutiveFailures = 0
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            consecutiveFailures += 1
                            guard consecutiveFailures < 3 else { throw error }
                            try await Task.sleep(for: .milliseconds(400 * consecutiveFailures))
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        Darwin.close(fd)
        fd = -1
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: partURL, to: destURL)
    }

    private static func downloadChunkRange(
        session: URLSession,
        delegate: StreamSessionDelegate,
        url: URL,
        headers: [String: String],
        fd: Int32,
        start: Int64,
        end: Int64,
        onWrite: @escaping @Sendable (Int) -> Void
    ) async throws {
        var req = URLRequest(url: url)
        applyHeaders(headers, to: &req)
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")

        let (response, stream, cancelStream) = try await delegate.stream(session: session, request: req)
        defer { cancelStream() }
        guard response.statusCode == 206 || response.statusCode == 200 else {
            throw YouTubeError("HTTP \(response.statusCode) downloading range \(start)-\(end).")
        }

        let maxExpected = end - start + 1
        var writtenForRange: Int64 = 0
        var offset = start

        // If server ignored Range and returned 200, only write the requested window [start, end].
        let isFull200 = response.statusCode == 200 && start > 0
        var streamPos: Int64 = 0

        try await withTaskCancellationHandler {
            for try await chunk in stream {
                try Task.checkCancellation()
                var slice = chunk
                if isFull200 {
                    let chunkEnd = streamPos + Int64(chunk.count)
                    if chunkEnd <= start {
                        streamPos = chunkEnd
                        continue
                    }
                    if streamPos < start {
                        let drop = Int(start - streamPos)
                        slice = chunk.dropFirst(drop)
                    }
                    streamPos = chunkEnd
                }

                let remaining = maxExpected - writtenForRange
                if remaining <= 0 { break }
                if Int64(slice.count) > remaining {
                    slice = slice.prefix(Int(remaining))
                }
                if slice.isEmpty { continue }

                try writeAll(fd: fd, data: slice, offset: offset)
                offset += Int64(slice.count)
                writtenForRange += Int64(slice.count)
                onWrite(slice.count)

                if writtenForRange >= maxExpected {
                    break
                }
            }
        } onCancel: {
            cancelStream()
        }
        guard writtenForRange == maxExpected else {
            throw URLError(.networkConnectionLost)
        }
    }

    private static func writeAll(fd: Int32, data: Data, offset: Int64) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < rawBuffer.count {
                let n = Darwin.pwrite(fd, base.advanced(by: totalWritten), rawBuffer.count - totalWritten, offset + Int64(totalWritten))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                totalWritten += n
            }
        }
    }

    // MARK: - Resume State

    private static func loadOrInitState(stateURL: URL, partURL: URL, totalSize: Int64, connections: Int) -> ResumeState {
        let partSize = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? Int64) ?? -1
        if partSize == totalSize,
           let existing = JSONFile.read(ResumeState.self, from: stateURL),
           existing.total == totalSize,
           !existing.chunks.isEmpty,
           existing.chunks.allSatisfy({ $0.start >= 0 && $0.end >= $0.start && $0.end < totalSize && $0.done >= 0 && $0.done <= ($0.end - $0.start + 1) }) {
            return existing
        }
        try? FileManager.default.removeItem(at: stateURL)
        var conns = max(1, connections)
        let minChunk: Int64 = 256 * 1024
        if totalSize / Int64(conns) < minChunk {
            conns = max(1, Int(totalSize / minChunk))
        }
        let chunkSize = totalSize / Int64(conns)
        var chunks: [ChunkState] = []
        var offset: Int64 = 0
        for i in 0..<conns {
            let end = (i == conns - 1) ? (totalSize - 1) : (offset + chunkSize - 1)
            chunks.append(ChunkState(start: offset, end: end, done: 0))
            offset = end + 1
        }
        return ResumeState(total: totalSize, chunks: chunks)
    }

    private static func writeResumeState(_ state: ResumeState, to url: URL) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func stateFileURL(for destURL: URL) -> URL {
        destURL.appendingPathExtension("state.json")
    }

    private static func applyHeaders(_ headers: [String: String], to request: inout URLRequest) {
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
    }
}

// MARK: - Streaming URLSession Delegate

private nonisolated final class StreamSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct TaskBridge {
        var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    }

    private let bridges = Mutex<[Int: TaskBridge]>([:])

    func stream(session: URLSession, request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>, @Sendable () -> Void) {
        let task = session.dataTask(with: request)
        let taskID = task.taskIdentifier

        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        let dataStream = AsyncThrowingStream<Data, Error> { cont in
            streamContinuation = cont
            cont.onTermination = { [weak self] _ in
                task.cancel()
                _ = self?.bridges.withLock { $0.removeValue(forKey: taskID) }
            }
        }

        let response: HTTPURLResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { respCont in
                bridges.withLock {
                    $0[taskID] = TaskBridge(
                        responseContinuation: respCont,
                        streamContinuation: streamContinuation
                    )
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
            let bridge = bridges.withLock { $0.removeValue(forKey: taskID) }
            bridge?.responseContinuation?.resume(throwing: CancellationError())
            bridge?.streamContinuation?.finish(throwing: CancellationError())
        }

        let cancelFn: @Sendable () -> Void = {
            task.cancel()
        }
        return (response, dataStream, cancelFn)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let respCont = bridges.withLock { dict -> CheckedContinuation<HTTPURLResponse, Error>? in
            let cont = dict[dataTask.taskIdentifier]?.responseContinuation
            dict[dataTask.taskIdentifier]?.responseContinuation = nil
            return cont
        }
        if let http = response as? HTTPURLResponse {
            respCont?.resume(returning: http)
            completionHandler(.allow)
        } else {
            respCont?.resume(throwing: YouTubeError("Unexpected non-HTTP response."))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let streamCont = bridges.withLock { $0[dataTask.taskIdentifier]?.streamContinuation }
        streamCont?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let bridge = bridges.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        guard let bridge else { return }
        if let error {
            let finalError: Error = (error as? URLError)?.code == .cancelled ? CancellationError() : error
            bridge.responseContinuation?.resume(throwing: finalError)
            bridge.streamContinuation?.finish(throwing: finalError)
        } else {
            bridge.responseContinuation?.resume(throwing: YouTubeError("Stream ended before HTTP response."))
            bridge.streamContinuation?.finish()
        }
    }
}
