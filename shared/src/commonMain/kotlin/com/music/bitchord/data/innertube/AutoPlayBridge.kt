package com.music.bitchord.data.innertube

import com.music.bitchord.data.model.Song
import com.music.bitchord.data.sources.TrackMatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Swift-facing bridge for the AutoPlay radio — the `next` endpoint that
 * returns related tracks after the current queue runs out.
 */
object AutoPlayBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }
    private val songListSerializer = ListSerializer(Song.serializer())

    fun interface AutoPlayCallback {
        fun onResult(json: String?, message: String?)
    }

    fun interface SeededAutoPlayCallback {
        fun onResult(seedVideoId: String?, json: String?, message: String?)
    }

    fun interface ResolveVideoIdCallback {
        fun onResult(videoId: String?, message: String?)
    }

    fun related(videoId: String, callback: AutoPlayCallback) {
        val generation = Innertube.sessionGeneration
        bridgeScope.launch {
            try {
                Innertube.checkSession(generation)
                val response = Innertube.next(videoId)
                val songs = InnertubeParser.parseWatchQueue(response)
                    .filterNot { it.isVideo }
                Innertube.checkSession(generation)
                callback.onResult(
                    json.encodeToString(songListSerializer, songs),
                    null,
                )
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    /**
     * Finds a matching YouTube video ID for a non-YouTube track (e.g. Add-on or Local track)
     * and fetches its radio watch queue via Innertube.next in a single roundtrip.
     */
    fun relatedForTrack(
        title: String,
        artist: String,
        durationSec: Int,
        album: String?,
        isExplicit: Boolean,
        callback: SeededAutoPlayCallback,
    ) {
        val generation = Innertube.sessionGeneration
        bridgeScope.launch {
            try {
                Innertube.checkSession(generation)
                val target = TrackMatcher.Target(
                    title = title,
                    artist = artist,
                    durationSec = if (durationSec > 0) durationSec else null,
                    album = album,
                    isExplicit = isExplicit,
                )
                var matchedVideoId: String? = null
                for (query in TrackMatcher.queries(target)) {
                    val searchResponse = Innertube.search(query)
                    val candidates = InnertubeParser.parseSearchSongs(searchResponse)
                    if (candidates.isEmpty()) continue
                    val ranked = TrackMatcher.ranked(candidates, target)
                    val best = if (target.durationSec != null) {
                        ranked.firstOrNull { TrackMatcher.withinSeconds(it, target, 5) } ?: ranked.firstOrNull()
                    } else {
                        ranked.firstOrNull()
                    } ?: candidates.firstOrNull()
                    if (best != null && best.videoId.isNotBlank()) {
                        matchedVideoId = best.videoId
                        break
                    }
                }
                val seedVideoId = matchedVideoId ?: throw IllegalStateException("No matching YouTube track found for '$title'")

                Innertube.checkSession(generation)
                val response = Innertube.next(seedVideoId)
                val songs = InnertubeParser.parseWatchQueue(response)
                    .filterNot { it.isVideo }
                Innertube.checkSession(generation)
                callback.onResult(
                    seedVideoId,
                    json.encodeToString(songListSerializer, songs),
                    null,
                )
            } catch (e: Throwable) {
                callback.onResult(null, null, e.message ?: e.toString())
            }
        }
    }

    /**
     * Resolves the canonical YouTube videoId for an arbitrary track using title, artist, and duration.
     */
    fun resolveVideoId(
        title: String,
        artist: String,
        durationSec: Int,
        callback: ResolveVideoIdCallback,
    ) {
        val generation = Innertube.sessionGeneration
        bridgeScope.launch {
            try {
                Innertube.checkSession(generation)
                val target = TrackMatcher.Target(
                    title = title,
                    artist = artist,
                    durationSec = if (durationSec > 0) durationSec else null,
                )
                var matchedVideoId: String? = null
                for (query in TrackMatcher.queries(target)) {
                    val searchResponse = Innertube.search(query)
                    val candidates = InnertubeParser.parseSearchSongs(searchResponse)
                    if (candidates.isEmpty()) continue
                    val ranked = TrackMatcher.ranked(candidates, target)
                    val best = if (target.durationSec != null) {
                        ranked.firstOrNull { TrackMatcher.withinSeconds(it, target, 5) } ?: ranked.firstOrNull()
                    } else {
                        ranked.firstOrNull()
                    } ?: candidates.firstOrNull()
                    if (best != null && best.videoId.isNotBlank()) {
                        matchedVideoId = best.videoId
                        break
                    }
                }
                callback.onResult(matchedVideoId, null)
            } catch (e: Throwable) {
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }
}
