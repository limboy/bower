import SwiftUI

struct DownloadsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let items = app.downloads.items
        let hasActive = items.contains { $0.status.isActive }
        let hasPaused = items.contains { $0.status == .paused }
        let hasFinished = items.contains { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }

        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No Downloads", systemImage: "arrow.down.circle")
                } description: {
                    Text("Download videos from their details or right-click menu.")
                }
            } else {
                VideoGrid {
                    ForEach(items) { item in
                        VideoCard(video: item.video, showsSource: true, downloadItem: item) {
                            VideoContextMenu(video: item.video, downloadItem: item)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .navigationSubtitle(subtitle)
        .toolbar {
            if !items.isEmpty {
                ToolbarItemGroup {
                    if hasActive {
                        Button {
                            app.downloads.pauseAll()
                        } label: {
                            Label("Pause All", systemImage: "pause.circle")
                        }
                        .help("Pause All Downloads")
                    }
                    if hasPaused {
                        Button {
                            app.downloads.resumeAll()
                        } label: {
                            Label("Resume All", systemImage: "play.circle")
                        }
                        .help("Resume All Downloads")
                    }
                    if hasFinished {
                        Button {
                            app.downloads.clearFinishedAndFailed()
                        } label: {
                            Label("Clear Finished", systemImage: "xmark.circle")
                        }
                        .help("Clear Completed and Failed Downloads from List")
                    }
                    Button {
                        app.downloads.openDownloadsFolder()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .help("Open Downloads Folder")
                }
            }
        }
    }

    private var subtitle: String {
        let count = app.downloads.items.count
        return count == 0 ? "" : "\(count) \(count == 1 ? "video" : "videos")"
    }
}

/// A progress ring with a stop symbol, spinning while the download size is unknown.
struct DownloadActivityIndicator: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: DownloadItem
    private let lineWidth: CGFloat = 1.5

    private var progress: Double? {
        guard item.status == .downloading else { return nil }
        let p = app.downloads.progress(for: item)
        return p.total > 0 ? p.fraction : nil
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: progress != nil || reduceMotion)) { context in
            let rotation = progress == nil && !reduceMotion
                ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
                : 0

            ZStack {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: lineWidth)
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: CGFloat(progress ?? 0.25))
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(rotation - 90))
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary)
                    .frame(width: 6, height: 6)
            }
        }
            .frame(width: 16, height: 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Download progress")
            .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "In progress")
            .help(progress.map { "Downloading (\(Int(($0 * 100).rounded()))%)" } ?? "Downloading")
    }
}
