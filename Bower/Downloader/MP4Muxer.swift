import Darwin
import Foundation

nonisolated enum MP4Muxer {
    struct Metadata: Sendable {
        var title: String = ""
        var artist: String = ""
        var date: String = ""
        var sourceURL: String = ""
        var artwork: Data?
    }

    private struct Box {
        var type: String
        var offset: Int64
        var size: Int64
        var hdrLen: Int64
        var data: Data = Data()
    }

    private struct FragPair {
        var trackID: UInt32
        var decodeTime: Double
        var moofData: Data
        var sourceURL: URL
        var mdatOffset: Int64
        var mdatSize: Int64
    }

    // MARK: - Public API

    @concurrent
    static func muxMP4(videoURL: URL, audioURL: URL, outputURL: URL, metadata: Metadata) async throws {
        let vf = try FileHandle(forReadingFrom: videoURL)
        defer { try? vf.close() }
        let af = try FileHandle(forReadingFrom: audioURL)
        defer { try? af.close() }

        let vBoxes = try scanFileBoxes(vf)
        let aBoxes = try scanFileBoxes(af)

        let vFrag = hasBox(vBoxes, "moof")
        let aFrag = hasBox(aBoxes, "moof")

        if vFrag && aFrag {
            try muxFragmentedMP4(
                vf: vf, vBoxes: vBoxes, videoURL: videoURL,
                af: af, aBoxes: aBoxes, audioURL: audioURL,
                outputURL: outputURL, metadata: metadata
            )
        } else if !vFrag && !aFrag {
            try muxStandardMP4(vf: vf, vBoxes: vBoxes, af: af, aBoxes: aBoxes, outputURL: outputURL, metadata: metadata)
        } else {
            throw YouTubeError("Mixed fragmented and standard MP4 tracks cannot be merged natively.")
        }
    }

    @concurrent
    static func tagMP4(inputURL: URL, outputURL: URL, metadata: Metadata) async throws {
        let f = try FileHandle(forReadingFrom: inputURL)
        defer { try? f.close() }

        let boxes = try scanFileBoxes(f)
        if hasBox(boxes, "moof") {
            try tagFragmentedMP4(f: f, boxes: boxes, outputURL: outputURL, metadata: metadata)
        } else {
            try tagStandardMP4(f: f, boxes: boxes, outputURL: outputURL, metadata: metadata)
        }
    }

    static func setMacWhereFrom(fileURL: URL, sourceURL: String) {
        guard !sourceURL.isEmpty else { return }
        let escaped = sourceURL
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let plist = """
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><array><string>\(escaped)</string></array></plist>
        """
        let data = Data(plist.utf8)
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = Darwin.setxattr(fileURL.path, "com.apple.metadata:kMDItemWhereFroms", base, data.count, 0, 0)
        }
    }

    // MARK: - Box Scanning & Parsing

    private static func scanFileBoxes(_ f: FileHandle) throws -> [Box] {
        let total = Int64(try f.seekToEnd())
        var boxes: [Box] = []
        var pos: Int64 = 0
        while pos + 8 <= total {
            try f.seek(toOffset: UInt64(pos))
            guard let hdr = try f.read(upToCount: 8), hdr.count == 8 else { break }
            let size32 = readUInt32BE(hdr, 0)
            let type = String(bytes: hdr.subdata(in: 4..<8), encoding: .isoLatin1) ?? "????"
            var hdrLen: Int64 = 8
            var size = Int64(size32)
            if size == 1 {
                guard let ext = try f.read(upToCount: 8), ext.count == 8 else {
                    throw YouTubeError("Truncated extended MP4 box \(type).")
                }
                size = Int64(bitPattern: readUInt64BE(ext, 0))
                hdrLen = 16
            } else if size == 0 {
                size = total - pos
            }
            guard size >= hdrLen, pos + size <= total else {
                throw YouTubeError("Corrupt MP4 box \(type) at \(pos).")
            }
            boxes.append(Box(type: type, offset: pos, size: size, hdrLen: hdrLen))
            pos += size
        }
        return boxes
    }

    private static func parseBoxes(from buf: Data) throws -> [Box] {
        var boxes: [Box] = []
        var pos = 0
        while pos + 8 <= buf.count {
            let size32 = readUInt32BE(buf, pos)
            let type = readFourCC(buf, pos + 4)
            var hdrLen = 8
            var size = Int64(size32)
            if size == 1 {
                guard pos + 16 <= buf.count else {
                    throw YouTubeError("Truncated extended box \(type).")
                }
                size = Int64(bitPattern: readUInt64BE(buf, pos + 8))
                hdrLen = 16
            } else if size == 0 {
                size = Int64(buf.count - pos)
            }
            guard size >= Int64(hdrLen), Int64(pos) + size <= Int64(buf.count) else {
                throw YouTubeError("Invalid MP4 box size \(size) for \(type).")
            }
            let start = buf.startIndex + pos
            let end = start + Int(size)
            boxes.append(Box(
                type: type,
                offset: Int64(pos),
                size: size,
                hdrLen: Int64(hdrLen),
                data: Data(buf[start..<end])
            ))
            pos += Int(size)
        }
        return boxes
    }

    private static func readBoxBytes(_ f: FileHandle, _ b: Box) throws -> Data {
        try f.seek(toOffset: UInt64(b.offset))
        guard let data = try f.read(upToCount: Int(b.size)), data.count == Int(b.size) else {
            throw YouTubeError("Unexpected EOF reading box \(b.type).")
        }
        return data
    }

    private static func hasBox(_ boxes: [Box], _ type: String) -> Bool {
        boxes.contains { $0.type == type }
    }

    private static func findBox(_ boxes: [Box], _ type: String) -> Box? {
        boxes.first { $0.type == type }
    }

    // MARK: - Standard MP4 Muxing

    private static func muxStandardMP4(
        vf: FileHandle,
        vBoxes: [Box],
        af: FileHandle,
        aBoxes: [Box],
        outputURL: URL,
        metadata: Metadata
    ) throws {
        guard let vMoovBox = findBox(vBoxes, "moov") else { throw YouTubeError("Video MP4 missing moov.") }
        guard let aMoovBox = findBox(aBoxes, "moov") else { throw YouTubeError("Audio MP4 missing moov.") }
        guard let vMdatBox = findBox(vBoxes, "mdat") else { throw YouTubeError("Video MP4 missing mdat.") }
        guard let aMdatBox = findBox(aBoxes, "mdat") else { throw YouTubeError("Audio MP4 missing mdat.") }

        let ftypBytes: Data
        if let fb = findBox(vBoxes, "ftyp"), let data = try? readBoxBytes(vf, fb) {
            ftypBytes = data
        } else {
            ftypBytes = defaultFtyp()
        }

        let vMoovRaw = try readBoxBytes(vf, vMoovBox)
        let aMoovRaw = try readBoxBytes(af, aMoovBox)

        let vChildren = try parseBoxes(from: vMoovRaw.dropFirst(Int(vMoovBox.hdrLen)))
        let aChildren = try parseBoxes(from: aMoovRaw.dropFirst(Int(aMoovBox.hdrLen)))

        guard let vMvhd = findBox(vChildren, "mvhd") else { throw YouTubeError("Video moov missing mvhd.") }
        var mvhdBytes = vMvhd.data
        if mvhdBytes.count >= 12 {
            writeUInt32BE(&mvhdBytes, 3, at: mvhdBytes.count - 4)
        }
        if let aMvhd = findBox(aChildren, "mvhd") {
            let (vDur, vTS) = readMvhdDuration(mvhdBytes)
            let (aDur, aTS) = readMvhdDuration(aMvhd.data)
            if vTS > 0, aTS > 0 {
                let aScaled = UInt64(Double(aDur) * Double(vTS) / Double(aTS))
                if aScaled > vDur {
                    writeMvhdDuration(&mvhdBytes, duration: aScaled)
                }
            }
        }

        guard let vTrak = findBox(vChildren, "trak") else { throw YouTubeError("Video moov missing trak.") }
        guard let aTrak = findBox(aChildren, "trak") else { throw YouTubeError("Audio moov missing trak.") }

        let vTrakBytes = rewriteTrackID(vTrak.data, newID: 1)
        let aTrakBytes = rewriteTrackID(aTrak.data, newID: 2)
        let udtaBytes = buildUdtaBox(metadata)

        let vPayloadStartOld = vMdatBox.offset + vMdatBox.hdrLen
        let vPayloadLen = vMdatBox.size - vMdatBox.hdrLen
        let aPayloadStartOld = aMdatBox.offset + aMdatBox.hdrLen
        let aPayloadLen = aMdatBox.size - aMdatBox.hdrLen

        let totalMdatPayload = vPayloadLen + aPayloadLen
        let mdatHdrLen: Int64 = (totalMdatPayload + 8 > 0xFFFF_FFFF) ? 16 : 8

        var vTrakFinal = vTrakBytes
        var aTrakFinal = aTrakBytes
        var moovBytes = Data()

        func buildMoov(vTrak: Data, aTrak: Data) -> Data {
            var payload = Data()
            payload.append(mvhdBytes)
            payload.append(vTrak)
            payload.append(aTrak)
            if !udtaBytes.isEmpty { payload.append(udtaBytes) }
            return makeBox("moov", payload)
        }

        for _ in 0..<2 {
            let measuredVLen = vTrakFinal.count
            let measuredALen = aTrakFinal.count
            moovBytes = buildMoov(vTrak: vTrakFinal, aTrak: aTrakFinal)

            let newVMdatStart = Int64(ftypBytes.count) + Int64(moovBytes.count) + mdatHdrLen
            let newAMdatStart = newVMdatStart + vPayloadLen

            vTrakFinal = try shiftTrakChunkOffsets(vTrakBytes, delta: newVMdatStart - vPayloadStartOld)
            aTrakFinal = try shiftTrakChunkOffsets(aTrakBytes, delta: newAMdatStart - aPayloadStartOld)
            if vTrakFinal.count == measuredVLen && aTrakFinal.count == measuredALen {
                moovBytes = buildMoov(vTrak: vTrakFinal, aTrak: aTrakFinal)
                break
            }
        }

        let tmpURL = outputURL.appendingPathExtension("muxtmp")
        try? FileManager.default.removeItem(at: tmpURL)
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmpURL)
        var succeeded = false
        defer {
            try? out.close()
            if !succeeded { try? FileManager.default.removeItem(at: tmpURL) }
        }

        try out.write(contentsOf: ftypBytes)
        try out.write(contentsOf: moovBytes)
        try out.write(contentsOf: mdatHeaderBytes(hdrLen: mdatHdrLen, payloadLen: totalMdatPayload))
        try copyFileRange(to: out, from: vf, offset: vPayloadStartOld, length: vPayloadLen)
        try copyFileRange(to: out, from: af, offset: aPayloadStartOld, length: aPayloadLen)
        try out.close()

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: tmpURL, to: outputURL)
        succeeded = true
    }

    private static func tagStandardMP4(
        f: FileHandle,
        boxes: [Box],
        outputURL: URL,
        metadata: Metadata
    ) throws {
        guard let moovBox = findBox(boxes, "moov") else { throw YouTubeError("MP4 missing moov.") }
        let mdatBoxes = boxes.filter { $0.type == "mdat" }
        guard mdatBoxes.count == 1, let mdatBox = mdatBoxes.first else {
            throw YouTubeError("MP4 must contain a single mdat box.")
        }

        let ftypBytes: Data
        if let fb = findBox(boxes, "ftyp"), let data = try? readBoxBytes(f, fb) {
            ftypBytes = data
        } else {
            ftypBytes = defaultFtyp()
        }

        let moovRaw = try readBoxBytes(f, moovBox)
        let children = try parseBoxes(from: moovRaw.dropFirst(Int(moovBox.hdrLen)))
        let udtaBytes = buildUdtaBox(metadata)

        var baseChildren = children.filter { $0.type != "udta" }.map(\.data)
        if !udtaBytes.isEmpty { baseChildren.append(udtaBytes) }

        let mdatPayloadOld = mdatBox.offset + mdatBox.hdrLen
        let mdatPayloadLen = mdatBox.size - mdatBox.hdrLen

        var currentChildren = baseChildren
        var moovBytes = makeBox("moov", Data(currentChildren.joined()))

        for _ in 0..<2 {
            let measuredMoovLen = moovBytes.count
            let mdatPayloadNew = Int64(ftypBytes.count) + Int64(measuredMoovLen) + mdatBox.hdrLen
            let delta = mdatPayloadNew - mdatPayloadOld

            var nextPayload = Data()
            var nextChildren: [Data] = []
            for child in baseChildren {
                if child.count >= 8, readFourCC(child, 4) == "trak" {
                    let shifted = try shiftTrakChunkOffsets(child, delta: delta)
                    nextChildren.append(shifted)
                    nextPayload.append(shifted)
                } else {
                    nextChildren.append(child)
                    nextPayload.append(child)
                }
            }
            currentChildren = nextChildren
            moovBytes = makeBox("moov", nextPayload)
            if moovBytes.count == measuredMoovLen { break }
        }

        let tmpURL = outputURL.appendingPathExtension("tagtmp")
        try? FileManager.default.removeItem(at: tmpURL)
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmpURL)
        var succeeded = false
        defer {
            try? out.close()
            if !succeeded { try? FileManager.default.removeItem(at: tmpURL) }
        }

        try out.write(contentsOf: ftypBytes)
        try out.write(contentsOf: moovBytes)
        try out.write(contentsOf: mdatHeaderBytes(hdrLen: mdatBox.hdrLen, payloadLen: mdatPayloadLen))
        try copyFileRange(to: out, from: f, offset: mdatPayloadOld, length: mdatPayloadLen)
        try out.close()

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: tmpURL, to: outputURL)
        succeeded = true
    }

    // MARK: - Fragmented MP4 Muxing

    private static func muxFragmentedMP4(
        vf: FileHandle, vBoxes: [Box], videoURL: URL,
        af: FileHandle, aBoxes: [Box], audioURL: URL,
        outputURL: URL, metadata: Metadata
    ) throws {
        guard let vMoovBox = findBox(vBoxes, "moov") else { throw YouTubeError("Video fMP4 missing moov.") }
        guard let aMoovBox = findBox(aBoxes, "moov") else { throw YouTubeError("Audio fMP4 missing moov.") }

        let ftypBytes: Data
        if let fb = findBox(vBoxes, "ftyp"), let data = try? readBoxBytes(vf, fb) {
            ftypBytes = data
        } else {
            ftypBytes = defaultFtyp()
        }

        let vMoovRaw = try readBoxBytes(vf, vMoovBox)
        let aMoovRaw = try readBoxBytes(af, aMoovBox)
        let vChildren = try parseBoxes(from: vMoovRaw.dropFirst(Int(vMoovBox.hdrLen)))
        let aChildren = try parseBoxes(from: aMoovRaw.dropFirst(Int(aMoovBox.hdrLen)))

        guard let vMvhd = findBox(vChildren, "mvhd") else { throw YouTubeError("Video moov missing mvhd.") }
        var mvhdBytes = vMvhd.data
        if mvhdBytes.count >= 12 {
            writeUInt32BE(&mvhdBytes, 3, at: mvhdBytes.count - 4)
        }
        writeMvhdDuration(&mvhdBytes, duration: 0)

        guard let vTrak = findBox(vChildren, "trak") else { throw YouTubeError("Video moov missing trak.") }
        guard let aTrak = findBox(aChildren, "trak") else { throw YouTubeError("Audio moov missing trak.") }

        let vTS = max(1, extractTrackTimescale(vTrak.data))
        let aTS = max(1, extractTrackTimescale(aTrak.data))

        let vTrakBytes = zeroTrackDurations(rewriteTrackID(vTrak.data, newID: 1))
        let aTrakBytes = zeroTrackDurations(rewriteTrackID(aTrak.data, newID: 2))

        var mvexPayload = Data()
        mvexPayload.append(buildOrRewriteTrex(vChildren, trackID: 1))
        mvexPayload.append(buildOrRewriteTrex(aChildren, trackID: 2))
        let mvexBytes = makeBox("mvex", mvexPayload)

        var moovPayload = Data()
        moovPayload.append(mvhdBytes)
        moovPayload.append(vTrakBytes)
        moovPayload.append(aTrakBytes)
        moovPayload.append(mvexBytes)
        let udta = buildUdtaBox(metadata)
        if !udta.isEmpty { moovPayload.append(udta) }
        let moovBytes = makeBox("moov", moovPayload)

        var frags = try collectFragPairs(vf: vf, boxes: vBoxes, trackID: 1, timescale: vTS, sourceURL: videoURL)
        frags += try collectFragPairs(vf: af, boxes: aBoxes, trackID: 2, timescale: aTS, sourceURL: audioURL)
        frags.sort { $0.decodeTime < $1.decodeTime }

        let tmpURL = outputURL.appendingPathExtension("muxtmp")
        try? FileManager.default.removeItem(at: tmpURL)
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmpURL)
        var succeeded = false
        defer {
            try? out.close()
            if !succeeded { try? FileManager.default.removeItem(at: tmpURL) }
        }

        try out.write(contentsOf: ftypBytes)
        try out.write(contentsOf: moovBytes)

        var curOffset = Int64(ftypBytes.count + moovBytes.count)
        for (i, frag) in frags.enumerated() {
            try Task.checkCancellation()
            let moof = rewriteMoof(frag.moofData, trackID: frag.trackID, seqNum: UInt32(i + 1), moofOffset: curOffset)
            try out.write(contentsOf: moof)
            let src = frag.trackID == 1 ? vf : af
            try copyFileRange(to: out, from: src, offset: frag.mdatOffset, length: frag.mdatSize)
            curOffset += Int64(moof.count) + frag.mdatSize
        }
        try out.close()

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: tmpURL, to: outputURL)
        succeeded = true
    }

    private static func tagFragmentedMP4(
        f: FileHandle,
        boxes: [Box],
        outputURL: URL,
        metadata: Metadata
    ) throws {
        guard let moovBox = findBox(boxes, "moov") else { throw YouTubeError("fMP4 missing moov.") }
        let moovRaw = try readBoxBytes(f, moovBox)
        let children = try parseBoxes(from: moovRaw.dropFirst(Int(moovBox.hdrLen)))

        var moovPayload = Data()
        for child in children where child.type != "udta" {
            if child.type == "mvhd" {
                var mvhd = child.data
                writeMvhdDuration(&mvhd, duration: 0)
                moovPayload.append(mvhd)
            } else if child.type == "trak" {
                moovPayload.append(zeroTrackDurations(child.data))
            } else {
                moovPayload.append(child.data)
            }
        }
        let udta = buildUdtaBox(metadata)
        if !udta.isEmpty { moovPayload.append(udta) }
        let newMoov = makeBox("moov", moovPayload)
        let delta = Int64(newMoov.count) - moovBox.size

        let tmpURL = outputURL.appendingPathExtension("tagtmp")
        try? FileManager.default.removeItem(at: tmpURL)
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmpURL)
        var succeeded = false
        defer {
            try? out.close()
            if !succeeded { try? FileManager.default.removeItem(at: tmpURL) }
        }

        var curOffset: Int64 = 0
        for b in boxes {
            try Task.checkCancellation()
            if b.type == "moov" {
                try out.write(contentsOf: newMoov)
                curOffset += Int64(newMoov.count)
            } else if b.type == "moof", delta != 0 {
                let raw = shiftMoofBaseDataOffset(try readBoxBytes(f, b), moofOffset: curOffset)
                try out.write(contentsOf: raw)
                curOffset += Int64(raw.count)
            } else {
                try copyFileRange(to: out, from: f, offset: b.offset, length: b.size)
                curOffset += b.size
            }
        }
        try out.close()

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: tmpURL, to: outputURL)
        succeeded = true
    }

    private static func collectFragPairs(
        vf: FileHandle,
        boxes: [Box],
        trackID: UInt32,
        timescale: UInt32,
        sourceURL: URL
    ) throws -> [FragPair] {
        var pairs: [FragPair] = []
        var i = 0
        while i + 1 < boxes.count {
            if boxes[i].type == "moof", boxes[i + 1].type == "mdat" {
                let moofData = try readBoxBytes(vf, boxes[i])
                let dt = extractMoofDecodeTime(moofData)
                pairs.append(FragPair(
                    trackID: trackID,
                    decodeTime: Double(dt) / Double(timescale),
                    moofData: moofData,
                    sourceURL: sourceURL,
                    mdatOffset: boxes[i + 1].offset,
                    mdatSize: boxes[i + 1].size
                ))
                i += 2
            } else {
                i += 1
            }
        }
        return pairs
    }

    // MARK: - Atom Manipulation Helpers

    private static func rewriteMoof(_ moof: Data, trackID: UInt32, seqNum: UInt32, moofOffset: Int64) -> Data {
        var out = moof
        guard let children = try? parseBoxes(from: out.dropFirst(8)) else { return out }
        for c in children {
            let cStart = 8 + Int(c.offset)
            if c.type == "mfhd", out.count >= cStart + 16 {
                writeUInt32BE(&out, seqNum, at: cStart + 12)
            } else if c.type == "traf" {
                let trafPayload = Data(out[(out.startIndex + cStart + 8)..<(out.startIndex + cStart + Int(c.size))])
                guard let tChildren = try? parseBoxes(from: trafPayload) else { continue }
                for tc in tChildren where tc.type == "tfhd" && tc.size >= 16 {
                    let tcStart = cStart + 8 + Int(tc.offset)
                    let flags = (UInt32(out[out.startIndex + tcStart + 9]) << 16)
                        | (UInt32(out[out.startIndex + tcStart + 10]) << 8)
                        | UInt32(out[out.startIndex + tcStart + 11])
                    writeUInt32BE(&out, trackID, at: tcStart + 12)
                    if (flags & 0x000001) != 0, tc.size >= 24 {
                        writeUInt64BE(&out, UInt64(bitPattern: moofOffset), at: tcStart + 16)
                    }
                }
            }
        }
        return out
    }

    private static func shiftMoofBaseDataOffset(_ moof: Data, moofOffset: Int64) -> Data {
        var out = moof
        guard let children = try? parseBoxes(from: out.dropFirst(8)) else { return out }
        for c in children where c.type == "traf" {
            let cStart = 8 + Int(c.offset)
            let trafPayload = Data(out[(out.startIndex + cStart + 8)..<(out.startIndex + cStart + Int(c.size))])
            guard let tChildren = try? parseBoxes(from: trafPayload) else { continue }
            for tc in tChildren where tc.type == "tfhd" && tc.size >= 24 {
                let tcStart = cStart + 8 + Int(tc.offset)
                let flags = (UInt32(out[out.startIndex + tcStart + 9]) << 16)
                    | (UInt32(out[out.startIndex + tcStart + 10]) << 8)
                    | UInt32(out[out.startIndex + tcStart + 11])
                if (flags & 0x000001) != 0 {
                    writeUInt64BE(&out, UInt64(bitPattern: moofOffset), at: tcStart + 16)
                }
            }
        }
        return out
    }

    private static func extractMoofDecodeTime(_ moof: Data) -> UInt64 {
        guard let children = try? parseBoxes(from: moof.dropFirst(8)) else { return 0 }
        for c in children where c.type == "traf" {
            guard let tChildren = try? parseBoxes(from: c.data.dropFirst(8)) else { continue }
            for tc in tChildren where tc.type == "tfdt" && tc.data.count >= 16 {
                let ver = tc.data[tc.data.startIndex + 8]
                if ver == 1, tc.data.count >= 20 {
                    return readUInt64BE(tc.data, 12)
                }
                return UInt64(readUInt32BE(tc.data, 12))
            }
        }
        return 0
    }

    private static func buildOrRewriteTrex(_ moovChildren: [Box], trackID: UInt32) -> Data {
        if let mvex = findBox(moovChildren, "mvex"),
           let mChildren = try? parseBoxes(from: mvex.data.dropFirst(8)),
           let trex = findBox(mChildren, "trex"), trex.data.count >= 16 {
            var out = trex.data
            writeUInt32BE(&out, trackID, at: 12)
            return out
        }
        var payload = Data(count: 20)
        writeUInt32BE(&payload, trackID, at: 0)
        writeUInt32BE(&payload, 1, at: 4)
        return makeFullBox("trex", version: 0, flags: 0, payload: payload)
    }

    private static func rewriteTrackID(_ trak: Data, newID: UInt32) -> Data {
        var out = trak
        guard let children = try? parseBoxes(from: out.dropFirst(8)) else { return out }
        for c in children where c.type == "tkhd" && c.data.count >= 24 {
            let cStart = 8 + Int(c.offset)
            let ver = out[out.startIndex + cStart + 8]
            if ver == 1, cStart + 32 <= out.count {
                writeUInt32BE(&out, newID, at: cStart + 28)
            } else if cStart + 24 <= out.count {
                writeUInt32BE(&out, newID, at: cStart + 20)
            }
        }
        return out
    }

    private static func zeroTrackDurations(_ trak: Data) -> Data {
        guard trak.count >= 8, let children = try? parseBoxes(from: trak.dropFirst(8)) else { return trak }
        var buf = Data()
        for c in children {
            if c.type == "tkhd" {
                var tkhd = c.data
                if tkhd.count >= 12 {
                    let ver = tkhd[tkhd.startIndex + 8]
                    if ver == 1, tkhd.count >= 44 {
                        writeUInt64BE(&tkhd, 0, at: 36)
                    } else if ver == 0, tkhd.count >= 32 {
                        writeUInt32BE(&tkhd, 0, at: 28)
                    }
                }
                buf.append(tkhd)
            } else if c.type == "mdia" {
                buf.append(zeroMediaDuration(c.data))
            } else {
                buf.append(c.data)
            }
        }
        return makeBox("trak", buf)
    }

    private static func zeroMediaDuration(_ mdia: Data) -> Data {
        guard mdia.count >= 8, let children = try? parseBoxes(from: mdia.dropFirst(8)) else { return mdia }
        var buf = Data()
        for c in children {
            if c.type == "mdhd" {
                var mdhd = c.data
                if mdhd.count >= 12 {
                    let ver = mdhd[mdhd.startIndex + 8]
                    if ver == 1, mdhd.count >= 40 {
                        writeUInt64BE(&mdhd, 0, at: 32)
                    } else if ver == 0, mdhd.count >= 28 {
                        writeUInt32BE(&mdhd, 0, at: 24)
                    }
                }
                buf.append(mdhd)
            } else {
                buf.append(c.data)
            }
        }
        return makeBox("mdia", buf)
    }

    private static func extractTrackTimescale(_ trak: Data) -> UInt32 {
        guard let children = try? parseBoxes(from: trak.dropFirst(8)) else { return 0 }
        for c in children where c.type == "mdia" {
            guard let mChildren = try? parseBoxes(from: c.data.dropFirst(8)) else { continue }
            for mc in mChildren where mc.type == "mdhd" && mc.data.count >= 24 {
                let ver = mc.data[mc.data.startIndex + 8]
                if ver == 1, mc.data.count >= 32 {
                    return readUInt32BE(mc.data, 28)
                }
                return readUInt32BE(mc.data, 20)
            }
        }
        return 0
    }

    private static func readMvhdDuration(_ mvhd: Data) -> (UInt64, UInt32) {
        guard mvhd.count >= 28 else { return (0, 0) }
        let ver = mvhd[mvhd.startIndex + 8]
        if ver == 1, mvhd.count >= 40 {
            return (readUInt64BE(mvhd, 32), readUInt32BE(mvhd, 28))
        }
        return (UInt64(readUInt32BE(mvhd, 24)), readUInt32BE(mvhd, 20))
    }

    private static func writeMvhdDuration(_ mvhd: inout Data, duration: UInt64) {
        guard mvhd.count >= 28 else { return }
        let ver = mvhd[mvhd.startIndex + 8]
        if ver == 1, mvhd.count >= 40 {
            writeUInt64BE(&mvhd, duration, at: 32)
        } else {
            writeUInt32BE(&mvhd, UInt32(truncatingIfNeeded: duration), at: 24)
        }
    }

    private static func shiftTrakChunkOffsets(_ trak: Data, delta: Int64) throws -> Data {
        guard trak.count >= 8 else { return trak }
        let children = try parseBoxes(from: trak.dropFirst(8))
        var buf = Data()
        for c in children {
            switch c.type {
            case "mdia", "minf", "stbl":
                buf.append(try shiftContainerChunkOffsets(type: c.type, payload: c.data.dropFirst(Int(c.hdrLen)), delta: delta))
            case "stco":
                buf.append(shiftStco(c.data, delta: delta))
            case "co64":
                buf.append(shiftCo64(c.data, delta: delta))
            default:
                buf.append(c.data)
            }
        }
        return makeBox("trak", buf)
    }

    private static func shiftContainerChunkOffsets(type: String, payload: Data, delta: Int64) throws -> Data {
        let children = try parseBoxes(from: payload)
        var buf = Data()
        for c in children {
            switch c.type {
            case "mdia", "minf", "stbl":
                buf.append(try shiftContainerChunkOffsets(type: c.type, payload: c.data.dropFirst(Int(c.hdrLen)), delta: delta))
            case "stco":
                buf.append(shiftStco(c.data, delta: delta))
            case "co64":
                buf.append(shiftCo64(c.data, delta: delta))
            default:
                buf.append(c.data)
            }
        }
        return makeBox(type, buf)
    }

    private static func shiftStco(_ data: Data, delta: Int64) -> Data {
        guard data.count >= 16 else { return data }
        let count = min(Int(readUInt32BE(data, 12)), max(0, (data.count - 16) / 4))
        var needCo64 = false
        for i in 0..<count {
            let off = Int64(readUInt32BE(data, 16 + i * 4)) + delta
            if off > 0xFFFF_FFFF || off < 0 {
                needCo64 = true
                break
            }
        }
        if !needCo64 {
            var out = data
            for i in 0..<count {
                let off = Int64(readUInt32BE(out, 16 + i * 4)) + delta
                writeUInt32BE(&out, UInt32(off), at: 16 + i * 4)
            }
            return out
        } else {
            var payload = Data(count: 4 + count * 8)
            writeUInt32BE(&payload, UInt32(count), at: 0)
            for i in 0..<count {
                let off = Int64(readUInt32BE(data, 16 + i * 4)) + delta
                writeUInt64BE(&payload, UInt64(bitPattern: off), at: 4 + i * 8)
            }
            return makeFullBox("co64", version: 0, flags: 0, payload: payload)
        }
    }

    private static func shiftCo64(_ data: Data, delta: Int64) -> Data {
        var out = data
        guard out.count >= 16 else { return out }
        let count = min(Int(readUInt32BE(out, 12)), max(0, (out.count - 16) / 8))
        for i in 0..<count {
            let off = Int64(bitPattern: readUInt64BE(out, 16 + i * 8)) + delta
            writeUInt64BE(&out, UInt64(bitPattern: off), at: 16 + i * 8)
        }
        return out
    }

    // MARK: - iTunes Metadata (udta)

    private static func buildUdtaBox(_ meta: Metadata) -> Data {
        var ilstBuf = Data()
        func addTextTag(_ atomBytes: [UInt8], _ val: String) {
            guard !val.isEmpty else { return }
            let valData = Data(val.utf8)
            var dataPayload = Data(count: 8 + valData.count)
            writeUInt32BE(&dataPayload, 1, at: 0) // UTF-8
            dataPayload.replaceSubrange(8..<(8 + valData.count), with: valData)
            let dataBox = makeBox("data", dataPayload)
            ilstBuf.append(makeBox(bytes: atomBytes, payload: dataBox))
        }

        addTextTag([0xa9, 0x6e, 0x61, 0x6d], meta.title)     // ©nam
        addTextTag([0xa9, 0x41, 0x52, 0x54], meta.artist)    // ©ART
        addTextTag([0xa9, 0x64, 0x61, 0x79], meta.date)      // ©day
        addTextTag([0xa9, 0x63, 0x6d, 0x74], meta.sourceURL) // ©cmt
        addTextTag([0xa9, 0x74, 0x6f, 0x6f], "Bower")        // ©too

        if let artwork = meta.artwork, artwork.count > 4 {
            let isPNG = artwork.prefix(4) == Data([0x89, 0x50, 0x4e, 0x47])
            let imgType: UInt32 = isPNG ? 14 : 13
            var dataPayload = Data(count: 8 + artwork.count)
            writeUInt32BE(&dataPayload, imgType, at: 0)
            dataPayload.replaceSubrange(8..<(8 + artwork.count), with: artwork)
            ilstBuf.append(makeBox("covr", makeBox("data", dataPayload)))
        }

        guard !ilstBuf.isEmpty else { return Data() }
        let hdlr = makeFullBox("hdlr", version: 0, flags: 0, payload: Data([
            0, 0, 0, 0,
            0x6d, 0x64, 0x69, 0x72, // mdir
            0x61, 0x70, 0x70, 0x6c, // appl
            0, 0, 0, 0,
            0, 0, 0, 0,
            0,
        ]))
        let ilst = makeBox("ilst", ilstBuf)
        var metaContent = Data()
        metaContent.append(hdlr)
        metaContent.append(ilst)
        let metaBox = makeFullBox("meta", version: 0, flags: 0, payload: metaContent)
        return makeBox("udta", metaBox)
    }

    // MARK: - Low-level Binary Helpers

    private static func makeBox(_ type: String, _ payload: Data) -> Data {
        let bytes = Array(type.utf8.prefix(4))
        return makeBox(bytes: bytes, payload: payload)
    }

    private static func makeBox(bytes: [UInt8], payload: Data) -> Data {
        let total = 8 + payload.count
        var out = Data(count: total)
        writeUInt32BE(&out, UInt32(total), at: 0)
        for i in 0..<min(4, bytes.count) { out[i + 4] = bytes[i] }
        if !payload.isEmpty {
            out.replaceSubrange(8..<total, with: payload)
        }
        return out
    }

    private static func makeFullBox(_ type: String, version: UInt8, flags: UInt32, payload: Data) -> Data {
        let total = 12 + payload.count
        var out = Data(count: total)
        writeUInt32BE(&out, UInt32(total), at: 0)
        let bytes = Array(type.utf8.prefix(4))
        for i in 0..<min(4, bytes.count) { out[i + 4] = bytes[i] }
        out[8] = version
        out[9] = UInt8((flags >> 16) & 0xFF)
        out[10] = UInt8((flags >> 8) & 0xFF)
        out[11] = UInt8(flags & 0xFF)
        if !payload.isEmpty {
            out.replaceSubrange(12..<total, with: payload)
        }
        return out
    }

    private static func defaultFtyp() -> Data {
        makeBox("ftyp", Data([
            0x69, 0x73, 0x6f, 0x6d, // isom
            0, 0, 2, 0,
            0x69, 0x73, 0x6f, 0x6d, // isom
            0x69, 0x73, 0x6f, 0x32, // iso2
            0x61, 0x76, 0x63, 0x31, // avc1
            0x6d, 0x70, 0x34, 0x31, // mp41
        ]))
    }

    private static func mdatHeaderBytes(hdrLen: Int64, payloadLen: Int64) -> Data {
        if hdrLen == 16 {
            var hdr = Data(count: 16)
            writeUInt32BE(&hdr, 1, at: 0)
            hdr.replaceSubrange(4..<8, with: Data("mdat".utf8))
            writeUInt64BE(&hdr, UInt64(16 + payloadLen), at: 8)
            return hdr
        }
        var hdr = Data(count: 8)
        writeUInt32BE(&hdr, UInt32(8 + payloadLen), at: 0)
        hdr.replaceSubrange(4..<8, with: Data("mdat".utf8))
        return hdr
    }

    private static func copyFileRange(to dst: FileHandle, from src: FileHandle, offset: Int64, length: Int64) throws {
        try src.seek(toOffset: UInt64(offset))
        var remaining = length
        let chunkSize = 1024 * 1024
        while remaining > 0 {
            try Task.checkCancellation()
            let toRead = Int(min(Int64(chunkSize), remaining))
            guard let data = try src.read(upToCount: toRead), !data.isEmpty else {
                throw YouTubeError("Unexpected EOF while muxing MP4.")
            }
            try dst.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
    }

    private static func readFourCC(_ data: Data, _ offset: Int) -> String {
        let s = data.startIndex + offset
        return String(bytes: data[s..<(s + 4)], encoding: .isoLatin1) ?? "????"
    }

    private static func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
        let s = data.startIndex + offset
        return (UInt32(data[s]) << 24)
            | (UInt32(data[s + 1]) << 16)
            | (UInt32(data[s + 2]) << 8)
            | UInt32(data[s + 3])
    }

    private static func readUInt64BE(_ data: Data, _ offset: Int) -> UInt64 {
        let hi = UInt64(readUInt32BE(data, offset))
        let lo = UInt64(readUInt32BE(data, offset + 4))
        return (hi << 32) | lo
    }

    private static func writeUInt32BE(_ data: inout Data, _ val: UInt32, at offset: Int) {
        let s = data.startIndex + offset
        data[s] = UInt8((val >> 24) & 0xFF)
        data[s + 1] = UInt8((val >> 16) & 0xFF)
        data[s + 2] = UInt8((val >> 8) & 0xFF)
        data[s + 3] = UInt8(val & 0xFF)
    }

    private static func writeUInt64BE(_ data: inout Data, _ val: UInt64, at offset: Int) {
        writeUInt32BE(&data, UInt32((val >> 32) & 0xFFFF_FFFF), at: offset)
        writeUInt32BE(&data, UInt32(val & 0xFFFF_FFFF), at: offset + 4)
    }
}
