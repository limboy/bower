import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ActiveSheet: String, Identifiable {
    case add, cookie, search
    var id: String { rawValue }
}

@Observable
final class AppModel {
    let store: LibraryStore
    let playback: PlaybackModel
    let library: LibraryService
    let downloads: DownloadManager

    @ObservationIgnored private var keepPlayerVisibleOnSelectionChange = false

    var selection: LibrarySelection? = .latest {
        didSet {
            guard selection != oldValue else { return }
            reloadDisplayed()
            if !keepPlayerVisibleOnSelectionChange {
                isPlayerVisible = false
            }
            filter = ""
        }
    }

    /// Narrows the visible list (grid and video list alike).
    var filter = "" {
        didSet { if filter != oldValue { applyFilter() } }
    }

    private(set) var filteredVideos: [Video] = []

    /// Lowercased title + source per displayed video, built on first use of
    /// the filter so typing doesn't redo it for every video on each key.
    @ObservationIgnored private var haystacks: [String]?

    /// The main area shows either the selected list as a grid of videos or,
    /// once a video is picked, the player with an optional video list.
    var isPlayerVisible = false

    private(set) var displayedVideos: [Video] = []

    var showVideoList: Bool = UserDefaults.standard.object(forKey: "showVideoList") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showVideoList, forKey: "showVideoList") }
    }

    var activeSheet: ActiveSheet?
    var alertMessage: String?
    private(set) var sidebarRevealToken = 0

    init() {
        let store = LibraryStore()
        let downloads = DownloadManager()
        self.store = store
        self.downloads = downloads
        playback = PlaybackModel(store: store, downloads: downloads)
        library = LibraryService(store: store)
        reloadDisplayed()
        Task { await CookieStore.shared.syncToWebKit(clearExisting: false) }
    }

    var displayedTitle: String {
        selection.map { store.title(for: $0) } ?? "Bower"
    }

    func reloadDisplayed() {
        displayedVideos = selection.map { videos(for: $0) } ?? []
        haystacks = nil
        applyFilter()
    }

    private func videos(for selection: LibrarySelection) -> [Video] {
        guard selection == .downloads else { return store.videos(for: selection) }
        var seen: Set<String> = []
        return downloads.items.compactMap { item in
            seen.insert(item.videoID).inserted ? item.video : nil
        }
    }

    /// Keep Downloads in the normal player queue and video-list inspector.
    func downloadsChanged() {
        playback.player.refreshDownloadSource()
        if selection == .downloads { reloadDisplayed() }
        if playback.queueContext == .downloads {
            playback.libraryChanged(videos(for: .downloads), context: .downloads)
        }
    }

    private func applyFilter() {
        let terms = filter.lowercased().split(separator: " ")
        guard !terms.isEmpty else {
            filteredVideos = displayedVideos
            return
        }
        let haystacks = haystacks ?? displayedVideos.map { "\($0.title) \($0.sourceTitle ?? "")".lowercased() }
        self.haystacks = haystacks
        filteredVideos = zip(displayedVideos, haystacks).compactMap { video, haystack in
            terms.allSatisfy { haystack.contains($0) } ? video : nil
        }
    }

    /// Sources' videos changed underneath: rebuild what is shown and the queue.
    func libraryChanged() {
        reloadDisplayed()
        if let selection, store.isMissing(selection) {
            self.selection = .latest
            return
        }
        if let context = playback.queueContext {
            let list = context == selection ? displayedVideos : videos(for: context)
            playback.libraryChanged(list, context: context)
        }
    }

    /// Bookmarks or history changed: only those two lists depend on them.
    func userDataChanged() {
        let dependent: Set<LibrarySelection> = [.bookmarks, .history]
        if let selection, dependent.contains(selection) { reloadDisplayed() }
        if let context = playback.queueContext, dependent.contains(context) {
            let list = context == selection ? displayedVideos : videos(for: context)
            playback.libraryChanged(list, context: context)
        }
    }

    func play(_ video: Video) {
        guard let selection else { return }
        playback.play(video, from: displayedVideos, context: selection)
        presentPlayer()
    }

    /// Plays the visible list from the top (or from a random video when
    /// shuffling), skipping hidden videos.
    func playAll() {
        let playable = displayedVideos.filter { !store.isSkipped($0.id) }
        guard let first = playback.shuffle ? playable.randomElement() : playable.first else { return }
        play(first)
    }

    func showPlayer() {
        guard playback.current != nil else { return }
        if let context = playback.queueContext, context != selection {
            selection = context
        }
        presentPlayer()
    }

    /// Shows `selection` with one of its videos cued, as when picking a
    /// search result.
    func reveal(_ videoID: String, in selection: LibrarySelection) {
        self.selection = selection
        if let video = displayedVideos.first(where: { $0.id == videoID }) {
            playback.play(video, from: displayedVideos, context: selection, autoplay: false)
            presentPlayer()
        }
    }

    var playingSourceRef: SourceRef? {
        guard let current = playback.current else { return nil }
        return store.sourceRef(for: current, context: playback.queueContext)
    }

    func revealPlayingSourceInSidebar() {
        guard let ref = playingSourceRef else { return }
        keepPlayerVisibleOnSelectionChange = true
        selection = LibrarySelection(ref)
        keepPlayerVisibleOnSelectionChange = false
        sidebarRevealToken += 1
    }

    private func presentPlayer() {
        if !isPlayerVisible { showVideoList = false }
        isPlayerVisible = true
    }

    func deleteSource(_ ref: SourceRef) {
        store.remove(ref)
    }

    func removeDownload(_ id: String) {
        do {
            try downloads.remove(ids: [id], trashFiles: true)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: Import / export

    func exportLibrary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [OPML.contentType]
        panel.nameFieldStringValue = "bower-export.opml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportOPML().write(to: url, options: .atomic)
        } catch {
            alertMessage = "Couldn't export the library: \(error.localizedDescription)"
        }
    }

    func importLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [OPML.contentType, .xml, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = try store.importData(Data(contentsOf: url))
            // OPML carries no videos, so fetch them for what was just added.
            library.refresh(added)
            alertMessage = added.count == 1 ? "Imported 1 playlist or channel." : "Imported \(added.count) playlists and channels."
        } catch {
            alertMessage = "That file isn't an OPML file or a Bower export."
        }
    }

    func flush() {
        playback.flush()
        store.flush()
        downloads.flush()
    }
}

extension LibraryStore {
    func isMissing(_ selection: LibrarySelection) -> Bool {
        switch selection {
        case .latest, .bookmarks, .history, .downloads: false
        case .folder(let id): folder(id) == nil
        case .playlist, .channel: selection.sourceRef.map { source($0) == nil } ?? true
        }
    }
}
