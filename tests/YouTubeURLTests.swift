import Foundation

/// Standalone regression suite; run `bash scripts/test-youtube-url.sh`.
/// Compiles the production parser directly, without adding an app target.
@main
struct YouTubeURLTests {
    static func main() {
        let id = "dQw4w9WgXcQ"
        var count = 0
        var failures = 0
        func check<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
            count += 1
            if actual != expected {
                failures += 1
                print("FAIL: \(name): expected \(expected), got \(actual)")
            }
        }

        let playable = [
            "https://youtube.com/watch?v=\(id)",
            "http://youtube.com/watch?v=\(id)",
            "https://www.youtube.com/watch?v=\(id)",
            "https://m.youtube.com/watch?v=\(id)",
            "https://music.youtube.com/watch?v=\(id)",
            "https://YOUTUBE.COM/watch?v=\(id)",
            "https://youtu.be/\(id)",
            "https://www.youtu.be/\(id)",
            "https://youtube.com/shorts/\(id)",
            "https://youtube.com/live/\(id)",
            "https://youtube.com/embed/\(id)",
            "https://youtube.com/v/\(id)",
            "https://youtube.com/WATCH?v=\(id)",
            "https://youtube.com/watch/?v=\(id)",
            "https://youtube.com/watch?v=\(id)&list=PL123",
            "https://youtu.be/\(id)?list=PL123",
            "https://youtube.com/watch?v=\(id)#t=90",
        ]
        for value in playable {
            check(value, YouTubeURL.videoLink(URL(string: value)!), .init(id: id, start: nil))
        }

        let rejected = [
            "https://youtube.com.evil.example/watch?v=\(id)",
            "https://notyoutube.com/watch?v=\(id)",
            "https://notyoutu.be/\(id)",
            "https://youtu.be.evil.example/\(id)",
            "https://youtube.com@evil.example/watch?v=\(id)",
            "https://example.com/watch?v=\(id)",
            "ftp://youtube.com/watch?v=\(id)",
            "file://youtube.com/watch?v=\(id)",
            "custom://youtube.com/watch?v=\(id)",
            "//youtube.com/watch?v=\(id)",
            "https://youtube.com/watch",
            "https://youtube.com/watch?v=",
            "https://youtube.com/playlist?list=PL123",
            "https://youtube.com/@channel",
            "https://youtube.com/results?search_query=video",
            "https://youtube.com/unknown?v=\(id)",
            "https://youtube.com/watch/extra?v=\(id)",
            "https://youtu.be/",
            "https://youtube.com/shorts/",
        ]
        for value in rejected {
            check(value, YouTubeURL.videoLink(URL(string: value)!), nil)
        }

        for value in ["abcdefghijk", "ABCDEFGHIJK", "01234567890", "aB0_-cD1eF2"] {
            check("valid ID \(value)", YouTubeURL.videoLink(URL(string: "https://youtu.be/\(value)")!)?.id, value)
        }
        for value in ["short", "abcdefghijkl", "abcdefghij!", "abcdefghijé", "abcdefghij中"] {
            check("invalid ID \(value)", YouTubeURL.videoLink(URL(string: "https://youtu.be/\(value)")!), nil)
        }

        // Keep a valid video even when its timestamp is unusable. Int32.max
        // seconds is the supported upper bound, including unit-form values.
        let times: [(String, Double?)] = [
            ("t=90", 90), ("start=90", 90), ("t=0", 0),
            ("t=-90", 0), ("start=-0.5", 0), ("t=1.5", 1.5),
            ("t=1e2", 100), ("t=90s", 90), ("t=1m", 60),
            ("t=1h", 3600), ("t=1m30s", 90), ("t=1h2m3s", 3723),
            ("t=1h3s", 3603), ("t=1H2M3S", 3723),
            ("t=0s", nil), ("t=0h0m0s", nil),
            ("t=abc", nil), ("t=1:30", nil), ("t=1.5m", nil),
            ("t=-1m", nil), ("t=1s2m", nil), ("t=1mgarbage", nil),
            ("t=90&start=120", 90), ("t=&start=120", 120),
            ("t=bad&start=120", nil), ("t=90&t=120", 90),
            ("T=90", nil), ("t=", nil), ("start=", nil),
            ("t=2147483647", 2147483647), ("t=2147483648", nil),
            ("t=2147483647s", 2147483647), ("t=2147483648s", nil),
            ("t=596523h14m7s", 2147483647), ("t=596523h14m8s", nil),
            ("t=nan", nil), ("t=NaN", nil), ("t=inf", nil),
            ("t=-inf", nil), ("t=infinity", nil), ("t=1e100", nil),
            ("t=1e309", nil), ("start=nan", nil), ("start=inf", nil),
            ("start=1e100", nil), ("t=999999999999999999999999h", nil),
            ("t=\(String(repeating: "9", count: 400))s", nil),
        ]
        for (query, expected) in times {
            check("timestamp \(query)", YouTubeURL.videoLink(URL(string: "https://youtube.com/watch?v=\(id)&\(query)")!), .init(id: id, start: expected))
        }

        // Add-sheet classification deliberately differs from clicked links.
        let unsupported = YouTubeURL.Kind.unsupported("Shorts and live streams aren't supported.")
        let classifications: [(String, YouTubeURL.Kind?)] = [
            ("youtube.com/watch?v=\(id)", .video(id: id)),
            ("  https://youtu.be/\(id)\n", .video(id: id)),
            ("https://youtube.com/watch?v=\(id)&list=PL123", .playlist(id: "PL123")),
            ("https://youtu.be/\(id)?list=PL123", .playlist(id: "PL123")),
            ("https://youtube.com/playlist?list=PL123", .playlist(id: "PL123")),
            ("https://youtube.com/shorts/\(id)?list=PL123", unsupported),
            ("https://youtube.com/live/\(id)", unsupported),
            ("https://youtube.com/embed/\(id)", .video(id: id)),
            ("https://youtube.com/v/\(id)", .video(id: id)),
            ("https://youtube.com/@name", .channel),
            ("https://youtube.com/@name/videos", .channel),
            ("https://youtube.com/channel/UC123", .channel),
            ("https://youtube.com/c/name", .channel),
            ("https://youtube.com/user/name", .channel),
            ("https://youtube.com/LegacyName", .channel),
            ("https://youtube.com/watch?v=legacy", .video(id: "legacy")),
            ("https://youtube.com/results", nil),
            ("https://youtube.com/playlist", nil),
            ("https://youtube.com/channel", nil),
            ("https://youtube.com/", nil),
            ("https://example.com/watch?v=\(id)", nil),
            ("", nil),
        ]
        for (value, expected) in classifications {
            check("classify \(value)", YouTubeURL.classify(value), expected)
        }
        print("YouTubeURL: \(count - failures)/\(count) checks passed")
        if failures > 0 { exit(1) }
    }
}
