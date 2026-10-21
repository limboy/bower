// Standalone regression for YouTubeURL parsing. Compiled against the app source:
//   bash scripts/test-youtube-url.sh
import Foundation

var failures = 0
@MainActor func expect(_ label: String, _ condition: Bool) {
    if condition { print("pass: \(label)") } else { failures += 1; print("FAIL: \(label)") }
}
@MainActor func isUnsupported(_ kind: YouTubeURL.Kind?) -> Bool {
    if case .unsupported = kind { return true }
    return false
}

// Video links
expect("watch?v", YouTubeURL.classify("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
expect("youtu.be path", YouTubeURL.classify("https://youtu.be/dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
expect("embed path", YouTubeURL.classify("https://www.youtube.com/embed/dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
expect("/v/ path", YouTubeURL.classify("https://www.youtube.com/v/dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))

// Playlist / channel classification (Add-sheet semantics)
expect("playlist id", YouTubeURL.classify("https://www.youtube.com/playlist?list=PL123456") == .playlist(id: "PL123456"))
expect("watch+list is playlist", YouTubeURL.classify("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123456") == .playlist(id: "PL123456"))
expect("channel @handle", { if case .channel = YouTubeURL.classify("https://www.youtube.com/@somecreator") { return true }; return false }())
expect("channel /c/", { if case .channel = YouTubeURL.classify("https://www.youtube.com/c/name") { return true }; return false }())
expect("shorts unsupported", isUnsupported(YouTubeURL.classify("https://www.youtube.com/shorts/abcdef")))
expect("live unsupported", isUnsupported(YouTubeURL.classify("https://www.youtube.com/live/abcdef")))

// Non-YouTube / junk
expect("other host nil", YouTubeURL.classify("https://example.com/watch?v=dQw4w9WgXcQ") == nil)
expect("subdomain youtube.com.evil nil", YouTubeURL.classify("https://youtube.com.evil.com/watch?v=dQw4w9WgXcQ") == nil)
expect("no scheme still parses host", YouTubeURL.classify("www.youtube.com/watch?v=dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))
expect("empty nil", YouTubeURL.classify("") == nil)
expect("plain word nil", YouTubeURL.classify("not a url") == nil)
expect("music.youtube host", YouTubeURL.classify("https://music.youtube.com/watch?v=dQw4w9WgXcQ") == .video(id: "dQw4w9WgXcQ"))

// Direct channel id / cleanup helpers
expect("directChannelID", YouTubeURL.directChannelID("https://www.youtube.com/channel/UCx123") == "UCx123")
expect("directChannelID needs UC", YouTubeURL.directChannelID("https://www.youtube.com/channel/xx123") == nil)
expect("cleanedChannelURL strips /videos", YouTubeURL.cleanedChannelURL("https://www.youtube.com/@some/videos") == "https://www.youtube.com/@some")

// Clicked-link routing (videoLink) — the video wins, unlike classify.
@MainActor func link(_ s: String) -> YouTubeURL.VideoLink? { URL(string: s).flatMap(YouTubeURL.videoLink) }

expect("videoLink watch", link("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == .init(id: "dQw4w9WgXcQ", start: nil))
expect("videoLink watch+list is video", link("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123") == .init(id: "dQw4w9WgXcQ", start: nil))
expect("videoLink t seconds", link("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90")?.start == 90)
expect("videoLink t=90s", link("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90s")?.start == 90)
expect("videoLink t=1m30s", link("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s")?.start == 90)
expect("videoLink t=1h2m3s", link("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1h2m3s")?.start == 3723)
expect("videoLink t=0 keeps 0", link("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=0")?.start == 0)
expect("videoLink junk t nil", link("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1x")?.start == nil)
expect("videoLink start=45", link("https://www.youtube.com/embed/dQw4w9WgXcQ?start=45")?.start == 45)
expect("videoLink youtu.be", link("https://youtu.be/dQw4w9WgXcQ?t=30") == .init(id: "dQw4w9WgXcQ", start: 30))
expect("videoLink shorts", link("https://www.youtube.com/shorts/dQw4w9WgXcQ")?.id == "dQw4w9WgXcQ")
expect("videoLink live", link("https://www.youtube.com/live/dQw4w9WgXcQ")?.id == "dQw4w9WgXcQ")
expect("videoLink embed", link("https://www.youtube.com/embed/dQw4w9WgXcQ")?.id == "dQw4w9WgXcQ")
expect("videoLink /v/", link("https://www.youtube.com/v/dQw4w9WgXcQ")?.id == "dQw4w9WgXcQ")
expect("videoLink uppercase scheme", link("HTTPS://WWW.YOUTUBE.COM/WATCH?v=dQw4w9WgXcQ")?.id == "dQw4w9WgXcQ")
expect("videoLink music subdomain", link("https://music.youtube.com/watch?v=dQw4w9WgXcQ")?.id == "dQw4w9WgXcQ")
expect("videoLink t preferred over start", link("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10&start=99")?.start == 10)

expect("videoLink playlist nil", link("https://www.youtube.com/playlist?list=PL123") == nil)
expect("videoLink handle nil", link("https://www.youtube.com/@somecreator") == nil)
expect("videoLink channel nil", link("https://www.youtube.com/channel/UCx123456789012345678") == nil)
expect("videoLink results nil", link("https://www.youtube.com/results?search_query=x") == nil)
expect("videoLink root ?v nil", link("https://www.youtube.com/?v=dQw4w9WgXcQ") == nil)
expect("videoLink watch extra path nil", link("https://www.youtube.com/watch/extra?v=dQw4w9WgXcQ") == nil)
expect("videoLink other site nil", link("https://example.com/watch?v=dQw4w9WgXcQ") == nil)
expect("videoLink evil suffix nil", link("https://youtube.com.evil.com/watch?v=dQw4w9WgXcQ") == nil)
expect("videoLink evil prefix nil", link("https://evilyoutube.com/watch?v=dQw4w9WgXcQ") == nil)
expect("videoLink javascript nil", link("javascript:alert(1)") == nil)
expect("videoLink mailto nil", link("mailto:a@b.c") == nil)
expect("videoLink ftp nil", link("ftp://youtube.com/watch?v=dQw4w9WgXcQ") == nil)
expect("videoLink schemeless URL nil", URL(string: "youtube.com/watch?v=dQw4w9WgXcQ").flatMap(YouTubeURL.videoLink) == nil)
expect("videoLink 10-char id nil", link("https://www.youtube.com/watch?v=dQw4w9WgXc") == nil)
expect("videoLink 12-char id nil", link("https://www.youtube.com/watch?v=dQw4w9WgXcQQ") == nil)
expect("videoLink id with = nil", link("https://www.youtube.com/watch?v=dQw4w9Wg=cQ") == nil)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
