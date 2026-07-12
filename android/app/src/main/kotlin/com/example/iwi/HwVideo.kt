package com.geogram.aurora

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream

/**
 * Hardware video playback for inline feed videos: android.media.MediaPlayer
 * (the OS's own decoder stack — MediaCodec underneath, zero bundled codecs)
 * rendering into a Flutter texture. The wasm decoder wapp remains the
 * fallback for files MediaPlayer rejects; the Dart side dispatches.
 *
 * Also hosts the poster fast path: a single video frame via
 * MediaMetadataRetriever (milliseconds, hardware-assisted) instead of the
 * wasm best-frame scan.
 *
 * MUST only be registered on the UI engine (MainActivity) — the headless
 * boot engine has no attached FlutterView, so its textures never render.
 */
class HwVideo(
    private val textureRegistry: TextureRegistry,
    messenger: BinaryMessenger,
) {
    companion object {
        const val CHANNEL = "com.geogram.aurora/hwvideo"
        const val EVENT_CHANNEL = "com.geogram.aurora/hwvideo_events"
    }

    private val players = mutableMapOf<Int, Player>()
    private var nextId = 1
    private var events: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "create" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("HWVIDEO", "path is required", null)
                        } else {
                            create(path, result)
                        }
                    }
                    "play" -> withPlayer(call.argument<Int>("id"), result) { it.mp.start(); true }
                    "pause" -> withPlayer(call.argument<Int>("id"), result) { it.mp.pause(); true }
                    "seek" -> withPlayer(call.argument<Int>("id"), result) {
                        it.mp.seekTo((call.argument<Number>("ms") ?: 0).toInt()); true
                    }
                    "position" -> withPlayer(call.argument<Int>("id"), result) { it.mp.currentPosition }
                    "duration" -> withPlayer(call.argument<Int>("id"), result) { it.mp.duration }
                    "dispose" -> {
                        players.remove(call.argument<Int>("id"))?.release()
                        result.success(true)
                    }
                    "thumbnail" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.success(null)
                        } else {
                            extractThumbnailAsync(
                                path,
                                (call.argument<Number>("atMs") ?: 1000).toLong(),
                                call.argument<Int>("maxPx") ?: 480,
                                result,
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("HWVIDEO", e.message, null)
            }
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                }
                override fun onCancel(args: Any?) {
                    events = null
                }
            },
        )
    }

    private inline fun withPlayer(
        id: Int?,
        result: MethodChannel.Result,
        block: (Player) -> Any?,
    ) {
        val p = players[id]
        if (p == null) {
            // A new Activity instance creates a new HwVideo with an empty map;
            // Dart treats this error as "orphaned player" and falls back.
            result.error("HWVIDEO", "unknown player id $id", null)
            return
        }
        try {
            result.success(block(p))
        } catch (e: Exception) {
            result.error("HWVIDEO", e.message, null)
        }
    }

    private fun create(path: String, result: MethodChannel.Result) {
        try {
            val id = nextId++
            val producer = textureRegistry.createSurfaceProducer()
            val mp = MediaPlayer()
            val p = Player(mp, producer)
            players[id] = p
            producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                // The producer's surface can be torn down while backgrounded
                // and recreated on resume — re-point the decoder at it.
                override fun onSurfaceAvailable() = p.safeSetSurface()
                override fun onSurfaceCleanup() {
                    try { mp.setSurface(null) } catch (_: Exception) {}
                }
            })
            mp.setDataSource(path) // local temp file written by the Dart side
            p.safeSetSurface()
            mp.setOnVideoSizeChangedListener { _, w, h ->
                if (w > 0 && h > 0) producer.setSize(w, h)
            }
            mp.setOnPreparedListener {
                emit(
                    mapOf(
                        "id" to id, "event" to "prepared",
                        "width" to mp.videoWidth, "height" to mp.videoHeight,
                        "durationMs" to mp.duration,
                    ),
                )
                try { mp.start() } catch (_: Exception) {}
            }
            mp.setOnCompletionListener { emit(mapOf("id" to id, "event" to "completed")) }
            mp.setOnErrorListener { _, what, extra ->
                emit(mapOf("id" to id, "event" to "error", "what" to what, "extra" to extra))
                true // handled — don't also fire onCompletion
            }
            mp.prepareAsync()
            result.success(mapOf("id" to id, "textureId" to producer.id()))
        } catch (e: Exception) {
            result.error("HWVIDEO", e.message, null)
        }
    }

    private fun emit(m: Map<String, Any?>) = main.post { events?.success(m) }

    fun dispose() {
        players.values.forEach { it.release() }
        players.clear()
    }

    private class Player(
        val mp: MediaPlayer,
        val producer: TextureRegistry.SurfaceProducer,
    ) {
        fun safeSetSurface() {
            try { mp.setSurface(producer.surface) } catch (_: Exception) {}
        }
        fun release() {
            try {
                mp.setSurface(null)
                mp.reset()
                mp.release()
            } catch (_: Exception) {}
            try { producer.release() } catch (_: Exception) {}
        }
    }

    /**
     * Poster fast path: one frame at [atMs] via MediaMetadataRetriever, on a
     * worker thread, downscaled to [maxPx] on the long edge, PNG bytes (null
     * on any failure — caller falls back to the wasm scan). Ported from the
     * proven geogram implementation.
     */
    private fun extractThumbnailAsync(
        path: String,
        atMs: Long,
        maxPx: Int,
        result: MethodChannel.Result,
    ) {
        Thread {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(path)
                val bitmap = retriever.getFrameAtTime(
                    atMs * 1000L, // µs
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                )
                if (bitmap == null) {
                    main.post { result.success(null) }
                    return@Thread
                }
                val scale = if (bitmap.width >= bitmap.height) {
                    maxPx.toFloat() / bitmap.width
                } else {
                    maxPx.toFloat() / bitmap.height
                }
                val out = if (scale < 1f) {
                    Bitmap.createScaledBitmap(
                        bitmap,
                        (bitmap.width * scale).toInt().coerceAtLeast(1),
                        (bitmap.height * scale).toInt().coerceAtLeast(1),
                        true,
                    )
                } else {
                    bitmap
                }
                val baos = ByteArrayOutputStream()
                out.compress(Bitmap.CompressFormat.PNG, 100, baos)
                val bytes = baos.toByteArray()
                if (out !== bitmap) out.recycle()
                bitmap.recycle()
                main.post { result.success(bytes) }
            } catch (e: Exception) {
                android.util.Log.w("HwVideo", "thumbnail failed for $path: ${e.message}")
                main.post { result.success(null) }
            } finally {
                try { retriever.release() } catch (_: Exception) {}
            }
        }.start()
    }
}
