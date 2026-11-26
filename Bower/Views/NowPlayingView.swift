import AppKit
import AVKit
import SwiftUI

struct NowPlayingView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        Group {
            if let video = playback.current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Group {
                            if let localPlayer = playback.player.localAVPlayer {
                                LocalPlayerSurface(player: localPlayer)
                            } else {
                                PlayerSurface(player: playback.player.youtube)
                            }
                        }
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)

                        VideoHeader(video: video)

                        Divider()

                        DescriptionSection()
                    }
                    .padding(24)
                    .frame(maxWidth: 1280)
                    .frame(maxWidth: .infinity)
                }
            } else {
                emptyState
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private var emptyState: some View {
        if app.store.isEmpty {
            ContentUnavailableView {
                Label("Welcome to Bower", systemImage: "play.rectangle.on.rectangle")
            } description: {
                Text("Follow YouTube channels and playlists without the algorithm. Paste a link to get started.")
            } actions: {
                Button("Add Playlist, Channel, or Video…") { app.activeSheet = .add }
                    .buttonStyle(.borderedProminent)
                Button("Import Library…") { app.importLibrary() }
            }
        } else {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "play.slash")
            } description: {
                Text(emptyMessage)
            }
        }
    }

    private var emptyTitle: String {
        switch app.selection {
        case .bookmarks: "No Bookmarks"
        case .history: "No History"
        case .hidden: "No Hidden Videos"
        default: "No Videos"
        }
    }

    private var emptyMessage: String {
        switch app.selection {
        case .bookmarks: "Bookmark videos from any list, or add a single video by its URL."
        case .history: "Videos you watch will show up here."
        case .hidden: "Videos you hide show up here."
        default: "Nothing to play here yet."
        }
    }
}

private struct VideoHeader: View {
    @Environment(AppModel.self) private var app
    @State private var isHoveringSource = false
    let video: Video

    var body: some View {
        let playback = app.playback
        let isBookmarked = app.store.isBookmarked(video.id)
        let isHidden = app.store.isSkipped(video.id)
        let sourceRef = app.playingSourceRef
        let sourceTitle = sourceRef.flatMap { app.store.source($0)?.title } ?? video.sourceTitle

        VStack(alignment: .leading, spacing: 10) {
            Button {
                NSWorkspace.shared.open(video.watchURL)
            } label: {
                Text(video.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Open in YouTube")

            HStack(spacing: 0) {
                if sourceRef != nil, let sourceTitle {
                    Button {
                        app.revealPlayingSourceInSidebar()
                    } label: {
                        Text(sourceTitle)
                            .foregroundStyle(isHoveringSource ? .primary : .secondary)
                            .underline(isHoveringSource)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringSource = $0 }
                    .help("Reveal \(sourceTitle) in Sidebar")
                } else if let sourceTitle {
                    Text(sourceTitle)
                }
                let trailing = [RelativeTime.format(video.publishedDate).nilIfEmpty, video.duration]
                    .compactMap { $0 }
                if !trailing.isEmpty {
                    let prefix = sourceTitle != nil ? " · " : ""
                    Text(prefix + trailing.joined(separator: " · "))
                }
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            HStack(spacing: 10) {
                ControlGroup {
                    Button { playback.previous() } label: { Label("Previous", systemImage: "backward.fill") }
                        .disabled(!playback.canGoPrevious && playback.player.currentTime <= 5)
                    Button { playback.togglePlayPause() } label: {
                        Label(playback.player.isPlaying ? "Pause" : "Play",
                              systemImage: playback.player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button { playback.next() } label: { Label("Next", systemImage: "forward.fill") }
                        .disabled(!playback.canGoNext)
                }
                .controlGroupStyle(.navigation)
                .fixedSize()

                ControlGroup {
                    Button { playback.shuffle.toggle() } label: {
                        Label {
                            Text("Shuffle")
                        } icon: {
                            Image(systemName: "shuffle")
                                .foregroundStyle(playback.shuffle ? Color.accentColor : .primary)
                        }
                    }
                    .help(playback.shuffle ? "Shuffle: On" : "Shuffle: Off")
                    Button { playback.loopMode = playback.loopMode.next } label: {
                        Label {
                            Text("Repeat")
                        } icon: {
                            Image(systemName: playback.loopMode == .one ? "repeat.1" : "repeat")
                                .foregroundStyle(playback.loopMode == .off ? Color.primary : Color.accentColor)
                        }
                    }
                    .help(repeatHelp(playback.loopMode))
                }
                .controlGroupStyle(.navigation)
                .fixedSize()

                Spacer()

                Button {
                    app.store.toggleBookmark(video)
                } label: {
                    Label(isBookmarked ? "Bookmarked" : "Bookmark", systemImage: isBookmarked ? "bookmark.fill" : "bookmark")
                }
                .help(isBookmarked ? "Remove Bookmark (⌘D)" : "Bookmark (⌘D)")

                Button {
                    if isHidden {
                        app.store.setSkipped(video.id, false)
                    } else {
                        app.playback.hide(video)
                    }
                } label: {
                    Label(isHidden ? "Unhide" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
                }
                .help(isHidden ? "Unhide — show in lists and playback again" : "Hide — remove from lists and skip during playback")

                downloadButton(for: video)

                ShareLink(item: video.watchURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Button {
                    NSWorkspace.shared.open(video.watchURL)
                } label: {
                    Label("Open in YouTube", systemImage: "safari")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.large)
            // The row reports a minimum far wider than it draws (~270pt more),
            // which pushed the columns past the window's minimum width.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func repeatHelp(_ mode: LoopMode) -> String {
        switch mode {
        case .off: "Repeat: Off"
        case .all: "Repeat: All"
        case .one: "Repeat: One"
        }
    }

    @ViewBuilder
    private func downloadButton(for video: Video) -> some View {
        let item = app.downloads.latestItem(for: video.id)
            ?? app.downloads.items.first { $0.videoID == video.id }
        if let item, item.status == .completed && item.fileExists {
            Menu {
                Button("Reveal in Finder") { app.downloads.revealInFinder(id: item.id) }
                Button("Show in Downloads") {
                    app.isPlayerVisible = false
                    app.selection = .downloads
                }
                Divider()
                Menu("Download Again") {
                    ForEach(DownloadQuality.allCases) { q in
                        Button(q.label) { app.downloads.enqueue(video: video, quality: q) }
                    }
                }
                Button("Remove Download", role: .destructive) {
                    app.removeDownload(item.id)
                }
            } label: {
                Label("Downloaded", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.primary)
            }
            .menuIndicator(.hidden)
            .help("Downloaded — Click for options")
        } else if let item, item.status == .paused {
            Button {
                app.downloads.resume(id: item.id)
            } label: {
                Label("Resume Download", systemImage: "play.circle")
            }
            .help("Resume Download")
        } else if let item, item.status.isActive {
            Button {
                app.removeDownload(item.id)
            } label: {
                Label {
                    Text("Cancel Download")
                } icon: {
                    Image(systemName: "arrow.down.circle")
                        .hidden()
                        .overlay {
                            DownloadActivityIndicator(item: item)
                                .allowsHitTesting(false)
                        }
                }
            }
            .help("Cancel Download and Remove Files")
        } else if let item, item.status == .failed || item.status == .cancelled || (item.status == .completed && !item.fileExists) {
            Button {
                app.downloads.retry(id: item.id)
            } label: {
                Label("Retry Download", systemImage: "arrow.clockwise")
            }
            .help("Retry Download")
        } else {
            Button {
                app.downloads.enqueue(video: video)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .help("Download Video")
        }
    }
}

private struct DescriptionSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        Group {
            if playback.isLoadingDescription {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading description…").foregroundStyle(.secondary)
                }
            } else if playback.descriptionText.isEmpty {
                Text("No description available")
                    .foregroundStyle(.tertiary)
            } else {
                DescriptionText(text: playback.descriptionText) { seconds in
                    playback.seek(to: Double(seconds))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LocalPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

/// Hosts the player's single WKWebView. SwiftUI may rebuild this container;
/// the web view itself (and whatever is playing) survives.
struct PlayerSurface: NSViewRepresentable {
    let player: YouTubePlayer

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if player.webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        let webView = player.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
