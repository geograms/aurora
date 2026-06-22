package com.geogram.aurora

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle

/**
 * Android MediaSession + MediaStyle notification for the Player wapp's music /
 * radio playback. Gives lock-screen and notification-shade transport controls
 * (play/pause/next/prev) that work with the screen off or another app open.
 *
 * The wapp (via Dart) calls [update] with the current title/state; button taps
 * — from the notification, the lock screen, or a headset — are forwarded back to
 * Dart as `media.action` on the bg_service channel, which the Player turns into
 * its existing playpause/next/prev commands.
 */
object MediaController {
    private const val CHANNEL_ID = "aurora_media"
    private const val NOTIF_ID = 7002
    const val ACTION = "com.geogram.aurora.MEDIA_ACTION"

    private var session: MediaSessionCompat? = null
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private var hasFocus = false

    fun sendAction(action: String) {
        try {
            (AuroraApplication.bgChannel ?: MainActivity.channel)
                ?.invokeMethod("media.action", mapOf("action" to action))
        } catch (_: Throwable) {
        }
    }

    private fun ensureSession(ctx: Context) {
        if (session != null) return
        val s = MediaSessionCompat(ctx, "AuroraPlayer")
        s.setCallback(object : MediaSessionCompat.Callback() {
            override fun onPlay() = sendAction("play")
            override fun onPause() = sendAction("pause")
            override fun onSkipToNext() = sendAction("next")
            override fun onSkipToPrevious() = sendAction("previous")
            override fun onStop() = sendAction("stop")
        })
        s.isActive = true
        session = s
    }

    @Synchronized
    fun update(
        ctx: Context,
        state: String,
        title: String,
        artist: String,
        durationMs: Long,
        positionMs: Long,
        canNext: Boolean,
        canPrev: Boolean,
    ) {
        val app = ctx.applicationContext
        ensureSession(app)
        val s = session ?: return
        val playing = state == "playing"
        if (playing) requestFocus(app)

        s.setMetadata(
            MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title.ifEmpty { "Aurora" })
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
                .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, if (durationMs > 0) durationMs else 0L)
                .build(),
        )

        var actions = PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or
            PlaybackStateCompat.ACTION_STOP
        if (canNext) actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_NEXT
        if (canPrev) actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
        s.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(actions)
                .setState(
                    if (playing) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                    if (positionMs > 0) positionMs else 0L,
                    1.0f,
                )
                .build(),
        )

        postNotification(app, s, playing, title, artist, canNext, canPrev)
    }

    @Synchronized
    fun stop(ctx: Context) {
        val app = ctx.applicationContext
        abandonFocus(app)
        session?.isActive = false
        val nm = app.getSystemService(NotificationManager::class.java)
        nm?.cancel(NOTIF_ID)
    }

    private fun actionPi(ctx: Context, action: String): PendingIntent {
        val i = Intent(ctx, MediaActionReceiver::class.java)
            .setAction(ACTION)
            .putExtra("action", action)
        return PendingIntent.getBroadcast(
            ctx, action.hashCode(), i,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun postNotification(
        ctx: Context,
        s: MediaSessionCompat,
        playing: Boolean,
        title: String,
        artist: String,
        canNext: Boolean,
        canPrev: Boolean,
    ) {
        createChannel(ctx)
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
        val contentPi = if (launch != null) {
            PendingIntent.getActivity(
                ctx, 0, launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        } else null

        val b = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(title.ifEmpty { "Aurora" })
            .setContentText(artist)
            .setOngoing(playing)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
        if (contentPi != null) b.setContentIntent(contentPi)

        val compact = ArrayList<Int>()
        var idx = 0
        if (canPrev) {
            b.addAction(android.R.drawable.ic_media_previous, "Previous", actionPi(ctx, "previous"))
            compact.add(idx++)
        }
        b.addAction(
            if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
            if (playing) "Pause" else "Play",
            actionPi(ctx, if (playing) "pause" else "play"),
        )
        compact.add(idx++)
        if (canNext) {
            b.addAction(android.R.drawable.ic_media_next, "Next", actionPi(ctx, "next"))
            compact.add(idx++)
        }

        b.setStyle(
            MediaStyle()
                .setMediaSession(s.sessionToken)
                .setShowActionsInCompactView(*compact.toIntArray()),
        )
        nm.notify(NOTIF_ID, b.build())
    }

    private fun createChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Now playing", NotificationManager.IMPORTANCE_LOW)
                    .apply { setShowBadge(false) },
            )
        }
    }

    // ── Audio focus ──
    private fun requestFocus(ctx: Context) {
        if (hasFocus) return
        val am = (audioManager ?: ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager)
            .also { audioManager = it }
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                -> sendAction("pause")
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setOnAudioFocusChangeListener(listener)
                .build()
            focusRequest = req
            hasFocus = am.requestAudioFocus(req) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            hasFocus = am.requestAudioFocus(
                listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN,
            ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonFocus(ctx: Context) {
        if (!hasFocus) return
        val am = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(null)
        }
        hasFocus = false
    }
}

/** Receives the notification's transport-button taps and forwards them to Dart. */
class MediaActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != MediaController.ACTION) return
        val action = intent.getStringExtra("action") ?: return
        MediaController.sendAction(action)
    }
}
