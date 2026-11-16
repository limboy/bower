import AppKit
import SwiftUI

/// The selected list as a grid of video cards — what the main area shows
/// until a video is picked.
struct VideoGridView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let videos = app.displayedVideos
        Group {
            if app.store.isEmpty && app.displayedVideos.isEmpty && app.selection != .bookmarks && app.selection != .history {
                welcome
            } else if app.displayedVideos.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptyIcon)
                } description: {
                    Text(emptyMessage)
                }
            } else {
                VideoGrid {
                    ForEach(videos) { video in
                        VideoCard(video: video, showsSource: showsSource) {
                            VideoContextMenu(video: video)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .navigationSubtitle(videos.isEmpty ? "" : subtitle)
    }

    private var showsSource: Bool {
        switch app.selection {
        case .playlist, .channel: false
        default: true
        }
    }

    private var subtitle: String {
        let count = app.displayedVideos.count
        var parts = ["\(count) \(count == 1 ? "video" : "videos")"]
        if let ref = app.selection?.sourceRef, let source = app.store.source(ref) {
            parts.append("updated \(RelativeTime.format(Date(timeIntervalSince1970: source.lastUpdated / 1000)))")
        }
        return parts.joined(separator: " · ")
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label("Welcome to Bower", systemImage: "play.rectangle.on.rectangle")
        } description: {
            Text("Follow YouTube channels and playlists without the algorithm. Paste a link to get started.")
        } actions: {
            Button("Add Playlist, Channel, or Video…") { app.activeSheet = .add }
                .buttonStyle(.borderedProminent)
            Button("Import Library…") { app.importLibrary() }
        }
    }

    private var emptyTitle: String {
        switch app.selection {
        case .bookmarks: "No Bookmarks"
        case .history: "No History"
        default: "No Videos"
        }
    }

    private var emptyIcon: String {
        switch app.selection {
        case .bookmarks: "bookmark"
        case .history: "clock.arrow.circlepath"
        default: "play.slash"
        }
    }

    private var emptyMessage: String {
        switch app.selection {
        case .bookmarks: "Bookmark videos from any list, or add a single video by its URL."
        case .history: "Videos you watch will show up here."
        default: "Nothing here yet. Check for new videos with ⌘R."
        }
    }
}

/// Shared spacing and sizing for every section's video cards.
struct VideoGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 20, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28, content: content)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 28)
        }
    }
}

struct VideoCard<MenuContent: View>: View {
    @Environment(AppModel.self) private var app
    let video: Video
    let showsSource: Bool
    var downloadItem: DownloadItem? = nil
    @ViewBuilder var contextMenuContent: () -> MenuContent

    @State private var isHovering = false

    var body: some View {
        let isSkipped = downloadItem == nil && app.store.isSkipped(video.id)
        let isBookmarked = app.store.isBookmarked(video.id)
        let isCurrent = app.playback.current?.id == video.id
        let badgeItem = downloadItem ?? app.downloads.latestItem(for: video.id)

        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { RemoteImage(url: video.thumbnail) }
                .overlay(alignment: .bottomLeading) {
                    if let badgeItem {
                        downloadBadge(for: badgeItem)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(video.duration)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
                .overlay {
                    if isCurrent {
                        ZStack {
                            Color.black.opacity(0.4)
                            Label("Now Playing", systemImage: app.playback.player.isPlaying ? "waveform" : "pause.fill")
                                .symbolEffect(.variableColor.iterative, isActive: app.playback.player.isPlaying)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    } else if isHovering {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                            .shadow(radius: 6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if downloadItem == nil && (isHovering || isBookmarked || isSkipped) {
                        HStack(spacing: 6) {
                            if isSkipped {
                                cardButton("eye", help: "Show — include in playback again") { app.store.setSkipped(video.id, false) }
                            } else {
                                if isHovering {
                                    cardButton("eye.slash", help: "Hide — skip during playback") { app.playback.hide(video) }
                                }
                                cardButton(isBookmarked ? "bookmark.fill" : "bookmark",
                                           help: isBookmarked ? "Remove Bookmark" : "Bookmark") { app.store.toggleBookmark(video) }
                            }
                        }
                        .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(isHovering ? 0.22 : 0.08), radius: isHovering ? 10 : 4, y: isHovering ? 5 : 2)
                .scaleEffect(isHovering ? 1.015 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.headline.weight(isCurrent ? .bold : .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !meta.isEmpty || downloadItem?.status.isActive == true {
                    HStack(spacing: 6) {
                        if !meta.isEmpty {
                            Text(meta)
                                .lineLimit(1)
                        }
                        if let downloadItem, downloadItem.status.isActive {
                            Button {
                                app.removeDownload(downloadItem.id)
                            } label: {
                                DownloadActivityIndicator(item: downloadItem)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Cancel Download")
                            .help("Cancel Download and Remove Files")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                if let downloadItem, downloadItem.status == .failed, let error = downloadItem.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(error)
                }
            }
        }
        .opacity(isSkipped ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .onTapGesture { activate() }
        .contextMenu { contextMenuContent() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(video.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activate() }
        .help(video.title)
    }

    private func activate() {
        if app.playback.current?.id == video.id {
            app.showPlayer()
        } else {
            app.play(video)
        }
    }

    private var meta: String {
        var parts: [String] = []
        if showsSource, let source = video.sourceTitle { parts.append(source) }
        if let date = video.publishedDate { parts.append(RelativeTime.format(date)) }
        if let downloadItem {
            parts.append(downloadItem.resolvedQualityLabel ?? downloadItem.quality.shortLabel)
        }
        return parts.joined(separator: " · ")
    }

    private func cardButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func downloadBadge(for item: DownloadItem) -> some View {
        if item.status == .completed && item.fileExists {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .help("Downloaded")
        } else if item.status.isActive {
            let p = app.downloads.progress(for: item)
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).colorScheme(.dark)
                if item.status == .merging {
                    Text("Merging")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                } else if item.status == .extracting {
                    Text("Preparing")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                } else if item.status == .queued {
                    Text("Queued")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                } else if p.total > 0 {
                    Text("\(Int((p.fraction * 100).rounded()))%")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.78), in: Capsule())
        } else if downloadItem != nil {
            switch item.status {
            case .paused:
                Button {
                    app.downloads.resume(id: item.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(item.totalBytes > 0 ? "Paused \(Int((item.fraction * 100).rounded()))%" : "Paused")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.78), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Resume Download")
            case .failed:
                Button {
                    app.downloads.retry(id: item.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("Retry")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.88), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(item.errorMessage ?? "Download failed — Click to retry")
            case .cancelled, .completed:
                Button {
                    app.downloads.retry(id: item.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .bold))
                        Text(item.status == .cancelled ? "Cancelled" : "Missing")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.78), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Click to retry download")
            default:
                EmptyView()
            }
        }
    }
}

/// Right-click actions shared by grid cards and list rows.
struct VideoContextMenu: View {
    @Environment(AppModel.self) private var app
    let video: Video
    var downloadItem: DownloadItem? = nil

    var body: some View {
        let isBookmarked = app.store.isBookmarked(video.id)
        Button("Play") { app.play(video) }
        Divider()
        Button(isBookmarked ? "Remove Bookmark" : "Bookmark") { app.store.toggleBookmark(video) }
        if app.store.isSkipped(video.id) {
            Button("Show in Lists") { app.store.setSkipped(video.id, false) }
        } else {
            Button("Hide from Playback") { app.playback.hide(video) }
        }
        Divider()
        downloadMenuItems
        Divider()
        Button("Open in YouTube") { NSWorkspace.shared.open(video.watchURL) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(video.watchURL.absoluteString, forType: .string)
        }
    }

    @ViewBuilder
    private var downloadMenuItems: some View {
        let item = downloadItem ?? app.downloads.latestItem(for: video.id)
            ?? app.downloads.items.first { $0.videoID == video.id }
        if let item {
            if item.status == .paused {
                Button("Resume Download") { app.downloads.resume(id: item.id) }
            } else if item.status.isActive {
                if item.status != .merging {
                    Button("Pause Download") { app.downloads.pause(id: item.id) }
                }
            } else if item.status == .completed && item.fileExists {
                Button("Reveal Downloaded File") { app.downloads.revealInFinder(id: item.id) }
            } else {
                Button("Retry Download") { app.downloads.retry(id: item.id) }
            }

            if app.selection != .downloads || app.isPlayerVisible {
                Button("Show in Downloads") {
                    app.isPlayerVisible = false
                    app.selection = .downloads
                }
            }

            if item.status == .completed && item.fileExists {
                Menu("Download Again") {
                    ForEach(DownloadQuality.allCases) { quality in
                        Button(quality.label) { app.downloads.enqueue(video: video, quality: quality) }
                    }
                }
            }

            Button("Remove Download", role: .destructive) {
                app.removeDownload(item.id)
            }
        } else {
            Button("Download Video") { app.downloads.enqueue(video: video) }
            Menu("Download Quality") {
                ForEach(DownloadQuality.allCases) { quality in
                    Button(quality.label) { app.downloads.enqueue(video: video, quality: quality) }
                }
            }
        }
    }
}
