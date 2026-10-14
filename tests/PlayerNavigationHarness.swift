// Methods under test are inserted directly from AppModel.swift by the runner.
// No LibraryStore, WKWebView, app launch, or persistent preferences are used.
import Foundation

final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Bool] = [:]
    func object(forKey key: String) -> Any? { values[key] }
}
struct Animation {
    static func smooth(duration: Double) -> Animation { Animation() }
}
var completions: [() -> Void] = []
func withAnimation(_ animation: Animation, _ body: () -> Void) { body() }
func withAnimation(_ animation: Animation, _ body: () -> Void, completion: @escaping () -> Void) {
    body()
    completions.append(completion)
}
func finishNextAnimation() { completions.removeFirst()() }
final class Player {
    var isPlaying = false
    var pauses = 0
    var plays = 0
    func pause() { pauses += 1; isPlaying = false }
    func play() { plays += 1; isPlaying = true }
}
final class Playback {
    var current: Int? = 1
    let player = Player()
}
enum LibrarySelection { case latest, history, bookmarks }
final class AppModel {
    let playback = Playback()
    var isPlayerVisible = false
    var isVideoListOpen = false
    var showVideoList = true
    var filter = ""
    func reloadDisplayed() {}
    // APPMODEL_DECLARATIONS
}

var failures = 0
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    assertions += 1
    if !condition() { failures += 1; print("FAIL: \(description)") }
}
func scenario(_ body: (AppModel) -> Void) {
    completions = []
    UserDefaults.standard.values = [:]
    body(AppModel())
}

scenario { model in
    model.playback.player.isPlaying = true
    model.selection = .history
    check(model.playback.player.pauses == 0, "sidebar browsing preserves mini-player audio")
    check(model.playback.player.isPlaying, "background audio keeps playing")
}
scenario { model in
    model.enterPlayer()
    model.playback.player.isPlaying = true
    model.selection = .history
    check(model.playback.player.pauses == 1, "leaving visible player pauses with default setting")
    check(!model.isPlayerVisible && !model.isVideoListOpen, "sidebar navigation hides player and list")
}
scenario { model in
    UserDefaults.standard.values["pauseWhenLeavingPlayer"] = false
    model.enterPlayer()
    model.playback.player.isPlaying = true
    model.leavePlayer()
    finishNextAnimation()
    check(model.playback.player.pauses == 0, "pause-disabled setting preserves audio")
    check(!model.isVideoListOpen, "normal leave closes list after fade")
}
scenario { model in
    model.openPlayer()
    model.selection = .history
    finishNextAnimation()
    check(!model.isPlayerVisible && !model.isVideoListOpen, "sidebar navigation cancels pending return")
    check(model.playback.player.plays == 0, "cancelled return never resumes playback")
}
scenario { model in
    model.openPlayer()
    check(!model.isPlayerVisible && model.isVideoListOpen, "return opens list before showing video")
    finishNextAnimation()
    check(model.isPlayerVisible && model.isVideoListOpen, "normal return shows video and list")
    check(model.playback.player.plays == 1, "normal return resumes paused playback")
}
scenario { model in
    UserDefaults.standard.values["resumeWhenReturningToPlayer"] = false
    model.showVideoList = false
    model.openPlayer()
    finishNextAnimation()
    check(model.isPlayerVisible && !model.isVideoListOpen, "return respects hidden-list preference")
    check(model.playback.player.plays == 0, "resume-disabled setting keeps playback paused")
}
scenario { model in
    model.enterPlayer()
    model.leavePlayer()
    model.openPlayer()
    finishNextAnimation()
    check(model.isVideoListOpen, "stale leave completion cannot close returning list")
    finishNextAnimation()
    check(model.isPlayerVisible && model.isVideoListOpen, "rapid leave-return finishes on player")
}
scenario { model in
    model.openPlayer()
    model.enterPlayer()
    finishNextAnimation()
    check(model.playback.player.plays == 0, "direct entry invalidates previous animated return")
}
scenario { model in
    model.playback.current = nil
    model.openPlayer()
    check(completions.isEmpty && !model.isPlayerVisible, "return without a current video does nothing")
}
scenario { model in
    model.playback.player.isPlaying = true
    model.openPlayer()
    finishNextAnimation()
    check(model.playback.player.plays == 0, "return does not restart already-playing audio")
}
print("\(assertions - failures)/\(assertions) navigation assertions passed")
if failures > 0 { exit(1) }
