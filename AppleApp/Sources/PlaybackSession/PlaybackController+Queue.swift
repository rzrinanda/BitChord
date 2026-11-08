import Foundation
import BitChordShared
import os
#if os(iOS)
import UIKit
#if DEBUG
import AVFoundation
#endif
#else
import AppKit
#endif

// Queue operations: playing a context, versions and upgrades, restoring the
// session, and editing what plays next.
extension PlaybackController {
    /// Plays `entries`, starting at `index`. Replaces the queue.
    func play(
        _ entries: [QueueEntry],
        at index: Int = 0,
        context: String? = nil,
        contextID: String? = nil,
        shuffleRequested: Bool? = nil,
        shuffleStart: Bool = false,
        boundedContext: Bool = false,
        continuationToken: String? = nil
    ) {
        noteLocalIntent()
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        if boundedContext, current?.id == entry.id, playbackContextID == contextID,
           !shuffleStart, shuffleRequested == nil || shuffleRequested == shuffleEnabled,
           state == .buffering || state == .playing {
            return
        }
        // Same song already loading or playing: extra taps are from the
        // download delay, not a request to restart.
        if !boundedContext, current?.id == entry.id,
           playbackContextID == contextID,
           !shuffleStart, shuffleRequested == nil || shuffleRequested == shuffleEnabled,
           queue.filter({ $0.contextOrder != nil }).sorted(by: { ($0.contextOrder ?? 0) < ($1.contextOrder ?? 0) }).map(\.id) == entries.map(\.id),
           state == .buffering || state == .playing {
            return
        }
        let useShuffle = shuffleRequested ?? shuffleEnabled
        let canonicalEntries = entries.enumerated().map { offset, value in
            var value = value
            value.contextOrder = offset
            value.fromAutoplay = false
            return value
        }
        var entries = canonicalEntries
        var index = index
        if shuffleStart, useShuffle, !automixSequencingEnabled {
            entries = PlaybackQueuePolicy.startingWith(entries, seed: Int.random(in: entries.indices))
            index = 0
        }
        let ordered = PlaybackQueuePolicy.orderList(
            entries, after: index, automix: automixSequencingEnabled,
            shuffle: useShuffle, scores: tasteScores(entries)
        )
        contextContinuationTask?.cancel()
        contextContinuationTask = nil
        contextWindowGeneration &+= 1
        contextWindowInstalling = true
        let materialized: [QueueEntry]
        let materializedIndex: Int
        if boundedContext, contextID != nil {
            playbackContextEntries = canonicalEntries
            contextWindowEntries = ordered
            playbackContextContinuation = continuationToken
            let range = PlaybackQueueWindow.initialRange(count: ordered.count, selectedIndex: index)
            materialized = Array(ordered[range])
            materializedIndex = index - range.lowerBound
            contextWindowBaseIndex = range.lowerBound
            contextWindowCursor = range.upperBound
        } else {
            playbackContextEntries = []
            contextWindowEntries = []
            playbackContextContinuation = nil
            contextWindowCursor = 0
            contextWindowBaseIndex = 0
            materialized = ordered
            materializedIndex = index
        }
        let selected = materialized[materializedIndex]
        queue = materialized
        playbackContext = context
        playbackContextID = contextID
        shuffleEnabled = useShuffle
        queueEditRevision &+= 1
        autoplayRefresh.invalidate()
        restoredStart = nil
        repeatAllStash = []
        repeatAllStashSeed = nil
        playingIndex = materializedIndex
        contextWindowInstalling = false
        playbackContextRevision &+= 1
        startEngineIfNeeded()
        if engineLoadedId == selected.id, current?.source == selected.source, state == .playing {
            current = queue[materializedIndex]
            persistSession()
            maybeAutoplay(force: true)
            syncEngineQueueNext()
            scheduleSequencing()
            return
        }
        loadCurrent(materializedIndex)
        maintainContextWindow()
    }

    var automixSequencingEnabled: Bool {
        automixEnabled && PlatformSettings.shared.getBoolean(key: "automix_smart_sequence", default: true)
    }

    func isPlaybackContextActive(_ contextID: String) -> Bool {
        playbackContextState(contextID) != .inactive
    }

    func isPlaybackContextPlaying(_ contextID: String) -> Bool {
        playbackContextState(contextID) == .playing
    }

    func ownsPlaybackContextWindow(_ contextID: String) -> Bool {
        playbackContextID == contextID && !playbackContextEntries.isEmpty
            && playbackContextState(contextID) != .inactive
    }

    private func playbackContextState(_ contextID: String) -> PlaybackQueuePolicy.HeroState {
        PlaybackQueuePolicy.heroState(
            origin: playbackContextID, listID: contextID, hasQueue: !queue.isEmpty,
            stopped: state == .stopped, playingOrBuffering: state == .playing || state == .buffering
        )
    }

    func togglePlaybackContext(
        _ entries: [QueueEntry],
        at index: Int = 0,
        title: String,
        contextID: String,
        shuffleRequested: Bool? = nil,
        continuationToken: String? = nil
    ) {
        if isPlaybackContextActive(contextID) {
            togglePlayPause()
        } else {
            play(entries, at: index, context: title, contextID: contextID, shuffleRequested: shuffleRequested,
                 shuffleStart: true, boundedContext: true, continuationToken: continuationToken)
        }
    }

    /// Keeps a detail-page context rolling forward without putting the entire
    /// fetched catalogue page into the active playback queue.
    func maintainContextWindow() {
        guard !contextWindowInstalling, contextWindowGeneration > 0,
              playbackContextID != nil, !playbackContextEntries.isEmpty else { return }
        trimPlayedContextPrefix()
        let upcoming = max(0, queue.count - playingIndex - 1)
        let available = max(0, contextWindowEntries.count - contextWindowCursor)
        let append = PlaybackQueueWindow.appendCount(upcomingCount: upcoming, canonicalRemaining: available)
        if append > 0 {
            let end = contextWindowCursor + append
            queue.append(contentsOf: contextWindowEntries[contextWindowCursor..<end])
            contextWindowCursor = end
            queueEditRevision &+= 1
            syncEngineQueueNext()
            persistSession()
        }
        let remaining = max(0, contextWindowEntries.count - contextWindowCursor)
        if PlaybackQueueWindow.shouldFetchContinuation(
            upcomingCount: max(0, queue.count - playingIndex - 1),
            canonicalRemaining: remaining,
            hasContinuation: playbackContextContinuation?.isEmpty == false
        ) {
            fetchContextContinuation()
        }
    }

    private func trimPlayedContextPrefix() {
        guard repeatMode != .all, playingIndex > 1 else { return }
        let removeCount = playingIndex - 1
        let removedContextRows = queue.prefix(removeCount).filter { $0.contextOrder != nil }.count
        contextWindowInstalling = true
        queue.removeFirst(removeCount)
        playingIndex -= removeCount
        contextWindowBaseIndex += removedContextRows
        queueEditRevision &+= 1
        contextWindowInstalling = false
    }

    /// Rematerializes a prior page row when Previous crosses the retained
    /// one-row history boundary of the rolling queue.
    func prependPreviousContextEntry() -> Bool {
        guard playbackContextID != nil, contextWindowBaseIndex > 0,
              contextWindowEntries.indices.contains(contextWindowBaseIndex - 1) else { return false }
        contextWindowBaseIndex -= 1
        queue.insert(contextWindowEntries[contextWindowBaseIndex], at: 0)
        playingIndex = 0
        return true
    }

    private func fetchContextContinuation() {
        guard contextContinuationTask == nil,
              let token = playbackContextContinuation, !token.isEmpty,
              let contextID = playbackContextID else { return }
        let generation = contextWindowGeneration
        contextContinuationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for (attempt, delay) in [0, 2, 5, 15].enumerated() {
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                }
                guard !Task.isCancelled, self.contextWindowGeneration == generation,
                      self.playbackContextID == contextID,
                      self.playbackContextContinuation == token else { return }
                do {
                    let page = try await InnertubeDetail.shared.more(token: token)
                    guard !Task.isCancelled, self.contextWindowGeneration == generation,
                          self.playbackContextID == contextID,
                          self.playbackContextContinuation == token else { return }
                    var known = Set(self.playbackContextEntries.map(\.id))
                    let fallbackArt = self.playbackContextEntries.first?.thumbnailUrl
                    var additions = page.songs.map { $0.asEntry(fallbackArt: fallbackArt) }
                        .filter { known.insert($0.id).inserted }
                    let firstOrder = self.playbackContextEntries.count
                    for index in additions.indices {
                        additions[index].contextOrder = firstOrder + index
                        additions[index].fromAutoplay = false
                    }
                    self.playbackContextEntries.append(contentsOf: additions)
                    self.contextWindowEntries.append(contentsOf: additions)
                    self.playbackContextContinuation = page.continuation == token || additions.isEmpty
                        ? nil : page.continuation
                    self.playbackContextRevision &+= 1
                    self.contextContinuationTask = nil
                    self.maintainContextWindow()
                    self.persistSession()
                    return
                } catch {
                    self.debugLog.record("detail continuation attempt \(attempt + 1) failed; retaining playback context token")
                }
            }
            if self.contextWindowGeneration == generation { self.contextContinuationTask = nil }
        }
    }

    // ---- Revert to original / upgrade quality --------------------------------

    /// A revert is only offered for a streamed YouTube track, because a track
    /// playing off a file the listener saved is not playing a stream anything
    /// chose. There is no "original" to go back to for a local file, JioSaavn or
    /// a remote-library row: those have no YouTube upload behind them at all.
    var canRevertToOriginal: Bool {
        guard let entry = current, let id = entry.videoId, entry.source.hasPrefix("yt:") else { return false }
        return !OriginalVersion.shared.isPinned(videoId: id) && !playingYouTubesOwn
    }

    /// The way back. A pinned track is held off the automatic search on purpose,
    /// so nothing but this row will ever offer it a better copy again.
    var canUpgradeQuality: Bool {
        guard let entry = current, let id = entry.videoId, entry.source.hasPrefix("yt:") else { return false }
        return OriginalVersion.shared.isPinned(videoId: id) || playingYouTubesOwn
    }

    /// Whether the currently playing source *is* YouTube's own stream for this
    /// track, whether the listener asked for that or an upgrade failed and was
    /// put back automatically.
    ///
    /// Kept as its own question because the two rows are offered on opposite
    /// sides of it: answering both from the pin alone would offer a revert for a
    /// track already on YouTube's upload, where the row would do nothing.
    private var playingYouTubesOwn: Bool {
        guard let entry = current, let origin = resolvedOrigin[entry.id] else { return false }
        return origin == .youtube || origin == .cache
    }

    /// Sends the playing track back to YouTube's own upload and holds it there.
    ///
    /// The position is kept: a listener who dislikes a substitute wants the song
    /// from where it was, not from the top. Upstream replaces the item with a
    /// direct-YouTube one, and the hold is what makes that stick past this queue
    /// entry — otherwise the next pass round the queue starts the whole
    /// substitution search again and lands them right back on the copy they
    /// rejected.
    func revertToOriginal() {
        guard let entry = current, let id = entry.videoId, entry.source.hasPrefix("yt:") else { return }
        OriginalVersion.shared.pin(videoId: id)
        // The cached file is whichever copy was downloaded, which for a track
        // being reverted is the one they just rejected. It has to go, or the
        // resolve hands it straight back and nothing appears to happen.
        Task { await StreamFileCache.shared.forget(videoId: id) }
        QualityUpgrade.forget(id)
        debugLog.record("reverted to YouTube's own upload", about: id)
        // Aligned only when version alignment is on: with it off no alignment
        // is attempted, so the reverted cut starts from the top.
        restartCurrent(keepingPosition: smartVersionAlignment)
    }

    /// The video toggle's other half: when a song's music video is a different
    /// cut (an intro, a skit, a longer ending), the picture cannot be laid over
    /// the song's audio, so the music-video upload plays instead — picture and
    /// sound from one file, always in step. YouTube Music's Song/Video switch
    /// and upstream's version swap do the same.
    ///
    /// The upload is pinned for as long as it plays: the catalogue substitution
    /// would otherwise send a music video straight back to the audio release.
    func playVideoVersion(videoId: String, durationText: String?) {
        guard let entry = current, entry.source.hasPrefix("yt:"), entry.videoId != videoId,
              queue.indices.contains(playingIndex) else { return }
        var version = QueueEntry.youtube(
            videoId: videoId, title: entry.title, artist: entry.artist,
            thumbnailUrl: entry.thumbnailUrl, durationText: durationText, albumName: entry.albumName,
            artistId: entry.artistId, albumId: entry.albumId, fromAutoplay: entry.fromAutoplay
        )
        version.contextOrder = entry.contextOrder
        songVersions[videoId] = entry
        OriginalVersion.shared.pin(videoId: videoId)
        queue[playingIndex] = version
        debugLog.record("video toggle: the music video \(videoId) plays in place of the song", about: entry.id)
        restartCurrent(keepingPosition: smartVersionAlignment)
    }

    /// Puts the song back where the video toggle had swapped in its music video.
    /// Does nothing when the playing entry is the song itself.
    func playSongVersion() {
        guard let entry = current, let song = songVersions.removeValue(forKey: entry.id),
              queue.indices.contains(playingIndex) else { return }
        OriginalVersion.shared.unpin(videoId: entry.id)
        queue[playingIndex] = song
        debugLog.record("video toggle: the song plays again in place of \(entry.id)", about: song.id)
        restartCurrent(keepingPosition: smartVersionAlignment)
    }

    /// Releases the hold and asks again, by hand, for a better copy.
    ///
    /// "By hand" is the load-bearing word: the automatic path may already have
    /// found this candidate and rejected it. This is also the only thing that
    /// clears a pin — an upgrade the app decided on by itself must never
    /// overturn a decision the listener made.
    func upgradeQuality() {
        guard let entry = current, let id = entry.videoId else { return }
        OriginalVersion.shared.unpin(videoId: id)
        QualityUpgrade.askByHand(id)
        debugLog.record("asked again for a better copy", about: id)
        restartCurrent(keepingPosition: smartVersionAlignment)
    }

    /// Reloads the playing entry so a new pin takes effect now rather than the
    /// next time the song comes round.
    func restartCurrent(keepingPosition: Bool) {
        guard queue.indices.contains(playingIndex) else { return }
        let resumeAt = keepingPosition ? position : 0
        // A restart is a new load, so the in-flight guard has to move: a resolve
        // started by the old source must not be able to `loadTrack` into the new.
        playGeneration &+= 1
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        engineLoadedId = nil
        loadedSourcePath = nil
        loadedSourceHeaders = [:]
        sourceHeadersByPath.removeAll(keepingCapacity: true)
        loadCurrent(playingIndex, startAt: resumeAt)
    }

    /// What the output is, for the audio pipeline panel. Read rather than
    /// observed: a panel that has to be told the device changed would be a
    /// panel nobody trusts.
    var outputDevice: OutputDeviceRec { engine.outputDevice() }

    var outputHealth: OutputHealthRec { engine.outputHealth() }

    func persistSession() {
        guard !queue.isEmpty, queue.indices.contains(playingIndex) else { return }
        PlatformSettings.shared.putString(key: "last_playback_context", value: playbackContext ?? "")
        var tracks = queue
        if duration > 0, tracks.indices.contains(playingIndex) {
            tracks[playingIndex].durationText = QueueEntry.formatDuration(duration)
        }
        LastPlayed.save(
            tracks: tracks,
            index: playingIndex,
            position: position,
            repeatMode: repeatMode,
            shuffleEnabled: shuffleEnabled,
            volume: volume,
            contextID: playbackContextID, contextTitle: playbackContext,
            contextEntries: playbackContextEntries,
            orderedContextEntries: contextWindowEntries,
            contextContinuation: playbackContextContinuation,
            contextCursor: contextWindowCursor,
            contextBaseIndex: contextWindowBaseIndex
        )
    }

    /// Remember where the track at `playingIndex` was left, so the resume can
    /// only ever be applied back to it. See `restoredStart`.
    private func rememberRestoredStart(_ position: Double, of entryId: String? = nil) {
        let id = entryId
            ?? (queue.indices.contains(playingIndex) ? queue[playingIndex].id : current?.id)
        restoredStart = id.map { (entryId: $0, position: position) }
    }

    func restoreSession() {
        guard let snap = LastPlayed.load() else { return }
        let savedContext = PlatformSettings.shared.getString(key: "last_playback_context", default: "")
        playbackContext = snap.contextTitle ?? (savedContext.isEmpty ? nil : savedContext)
        playbackContextID = snap.contextID
        contextContinuationTask?.cancel()
        contextContinuationTask = nil
        contextWindowGeneration &+= 1
        contextWindowInstalling = true
        playbackContextEntries = snap.contextEntries
        contextWindowEntries = snap.orderedContextEntries
        playbackContextContinuation = snap.contextContinuation
        contextWindowCursor = min(max(0, snap.contextCursor), contextWindowEntries.count)
        contextWindowBaseIndex = min(max(0, snap.contextBaseIndex), contextWindowEntries.count)
        queue = snap.tracks
        playingIndex = snap.index
        contextWindowInstalling = false
        current = queue[snap.index]
        position = snap.position
        duration = current?.durationSeconds ?? 0
        repeatMode = snap.repeatMode
        shuffleEnabled = snap.shuffleEnabled
        volume = snap.volume
        repeatAllStash = []
        repeatAllStashSeed = nil
        rememberRestoredStart(snap.position, of: current?.id)
        maintainContextWindow()
        dolbyRenderer?.stop()
        dolbyRenderer = nil
        engineLoadedId = nil
        loadedSourcePath = nil
        loadedSourceHeaders = [:]
        sourceHeadersByPath.removeAll(keepingCapacity: true)
        state = .paused
        if let entry = current {
            nowPlaying.update(
                id: entry.id, title: entry.title, artist: entry.artist,
                duration: duration, artworkData: entry.artworkData,
                thumbnailUrl: entry.thumbnailUrl, isPlaying: false, position: position
            )
            widgetPublisher.publish(entry: entry, isPlaying: false,
                                    canNext: playingIndex + 1 < queue.count,
                                    canPrevious: playingIndex > 0)
            // A restored track is paused, not unloaded: its lyric is a network
            // lookup with no audio behind it, and without it the pane claims
            // "No lyrics for this track." about a song nobody has asked yet.
            fetchLyrics(for: entry)
        }
    }

    func playNext(_ entry: QueueEntry) {
        playNext([entry])
    }

    /// A collection's "play next": the batch inserts once, in order — looping
    /// the single-entry form would insert each song in front of the one before
    /// it and the album would play next backwards.
    ///
    /// On an idle player this is still a request to play, and it starts with
    /// the collection's first track: the array lands whole at the playing
    /// slot, so `loadCurrent` picks index 0 of it.
    func playNext(_ entries: [QueueEntry]) {
        guard !entries.isEmpty else { return }
        noteLocalIntent()
        let wasEmpty = queue.isEmpty
        let prepared = entries.map { entry -> QueueEntry in
            var entry = entry
            entry.contextOrder = nil
            entry.fromAutoplay = false
            return entry
        }
        // Each entry must not displace an autoplay entry another one just
        // added; dedupe against the queue once for the batch.
        for entry in prepared {
            removeAutoplayDuplicate(of: entry)
        }
        let at = min(playingIndex + 1, queue.count)
        queue.insert(contentsOf: prepared, at: at)
        queueEditRevision &+= 1
        persistSession()
        // As `addToQueue`: "play next" on an idle player is a request to play.
        if wasEmpty, isIdle {
            playingIndex = 0
            loadCurrent(0)
            return
        }
        syncEngineQueueNext()
    }

    /// Upstream `playRadio`: seed plus related mix via `next` + QueueBuilder.
    func playRadio(_ entry: QueueEntry, context: String? = nil) {
        autoplayEnabled = true
        play([entry], at: 0, context: context ?? "Radio")
    }

    /// SwiftUI `onMove` entry: destination is the pre-remove insertion index.
    func moveQueue(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        let media3 = destination > from ? destination - 1 : destination
        moveQueueItem(from: from, to: media3)
    }

    /// Media3 `moveMediaItem(from, to)`: the item at `from` lands at `to`.
    /// Upcoming tracks only; a drag never crosses the manual/autoplay boundary.
    func moveQueueItem(from: Int, to requested: Int) {
        guard queue.indices.contains(from), from != playingIndex else { return }
        let section = autoplaySectionStart
        let inMix = from >= section
        let lo = inMix ? section : playingIndex + 1
        let hi = inMix ? queue.count : section
        guard from >= lo, from < hi || (inMix && from < queue.count) else { return }
        let maxTo = inMix ? queue.count - 1 : max(lo, hi - 1)
        var to = min(max(requested, lo), maxTo)
        if !inMix { to = min(to, hi - 1) }
        if to == from || to < lo { return }
        var copy = queue
        var item = copy.remove(at: from)
        if !inMix { item.contextOrder = nil }
        let insertAt = min(max(to, 0), copy.count)
        copy.insert(item, at: insertAt)
        queue = copy
        queueEditRevision &+= 1
        persistSession()
        syncEngineQueueNext()
    }

    /// Where AutoPlay's section begins — heading index and play-next insertion point.
    var autoplaySectionStart: Int {
        Self.autoplaySectionStart(fromAutoplay: queue.map(\.fromAutoplay), currentIndex: playingIndex)
    }

    /// First upcoming index that may be dragged in the manual section.
    var firstMovableQueueIndex: Int {
        min(playingIndex + 1, autoplaySectionStart)
    }

    static func autoplaySectionStart(fromAutoplay: [Bool], currentIndex: Int) -> Int {
        let after = min(max(currentIndex + 1, 0), fromAutoplay.count)
        if after >= fromAutoplay.count { return fromAutoplay.count }
        return (after..<fromAutoplay.count).first { fromAutoplay[$0] } ?? fromAutoplay.count
    }

    /// Upstream `addToQueue`: the item joins the end of what the *listener*
    /// queued, which outranks whatever AutoPlay lined up behind it.
    ///
    /// Adding to an idle player is also how playback *starts*. Upstream inserts
    /// into the player's own playlist, and ExoPlayer takes an item added to an
    /// empty playlist as the thing to play; the port appended to its model and
    /// called `syncEngineQueueNext`, which looks at the item *after* the
    /// playing one — and with nothing playing there is no such item. The song
    /// then simply sat there until Next was pressed.
    func addToQueue(_ entry: QueueEntry) {
        noteLocalIntent()
        let wasEmpty = queue.isEmpty
        var entry = entry
        entry.contextOrder = nil
        entry.fromAutoplay = false
        removeAutoplayDuplicate(of: entry)
        let at = min(autoplaySectionStart, queue.count)
        queue.insert(entry, at: at)
        queueEditRevision &+= 1
        persistSession()
        if wasEmpty, isIdle {
            // Nothing was playing and nothing was queued: this is the queue.
            playingIndex = 0
            loadCurrent(0)
            return
        }
        syncEngineQueueNext()
    }

    private func removeAutoplayDuplicate(of entry: QueueEntry) {
        let duplicateIndices = queue.indices.filter {
            $0 > playingIndex && queue[$0].fromAutoplay && queue[$0].id == entry.id
        }
        guard !duplicateIndices.isEmpty else { return }
        queue.remove(atOffsets: IndexSet(duplicateIndices))
    }

    /// Nothing loaded into the engine and nothing on its way there.
    private var isIdle: Bool {
        engineLoadedId == nil && state != .playing && state != .buffering
    }

    /// Run `body` without its transport changes being reported as the listener's.
    func withLocalIntentSuppressed<T>(_ body: () -> T) -> T {
        intentSuppression += 1
        defer { intentSuppression -= 1 }
        return body()
    }

    func noteLocalIntent() {
        guard intentSuppression == 0 else { return }
        onLocalIntent?()
    }
}
