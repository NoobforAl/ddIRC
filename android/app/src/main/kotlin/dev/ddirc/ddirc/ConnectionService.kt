package dev.ddirc.ddirc

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the process alive while ddIRC is not the app in front.
 *
 * There is nothing here that holds the connections. They live in the Rust core,
 * on its own threads, inside this process, and they keep running for as long as
 * the process does. What Android takes away — and what this gives back — is the
 * *right* to keep running: an app the user is not looking at is a cached
 * process, and a cached process is the first thing killed when memory is short.
 * A foreground service moves it out of that queue, and the price Android
 * charges for that is a notification the user can see and dismiss the app from.
 *
 * So this is deliberately thin. It shows a notification, it keeps the process
 * out of the reaper's way, and it forwards two decisions back to Dart, which is
 * where every decision in this app already lives.
 */
class ConnectionService : Service() {

    companion object {
        /** The channel is the user's control over this: they can silence it. */
        const val CHANNEL_ID = "connection"
        private const val NOTIFICATION_ID = 1

        const val ACTION_START = "dev.ddirc.ddirc.action.START"
        const val ACTION_UPDATE = "dev.ddirc.ddirc.action.UPDATE"
        const val ACTION_STOP = "dev.ddirc.ddirc.action.STOP"

        /** The notification's own button. */
        const val ACTION_QUIT = "dev.ddirc.ddirc.action.QUIT"

        const val EXTRA_STATUS = "status"

        /**
         * Called when the notification's Quit button is pressed, and when the
         * task is swiped away.
         *
         * Set by [MainActivity] while the engine is attached, because Dart is
         * what knows how to say goodbye to a server. Null once the engine is
         * gone, in which case there is nobody left to ask and the service can
         * only stop.
         */
        @Volatile
        var onQuitRequested: (() -> Unit)? = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START, ACTION_UPDATE -> {
                val status = intent.getStringExtra(EXTRA_STATUS).orEmpty()
                if (intent.action == ACTION_START) {
                    startInForeground(status)
                } else {
                    notificationManager().notify(NOTIFICATION_ID, build(status))
                }
            }

            ACTION_STOP -> stopEverything()

            // The user pressed Quit on the notification. Dart closes the
            // connections, sending a QUIT to each server, and comes back here
            // through ACTION_STOP. If there is no engine to ask, stop anyway
            // rather than leaving a notification nothing is behind.
            ACTION_QUIT -> onQuitRequested?.invoke() ?: stopEverything()
        }
        // Never restarted on its own. A service that comes back without the app
        // behind it would be a notification claiming a connection that is not
        // there, which is worse than being gone.
        return START_NOT_STICKY
    }

    /**
     * The app was swiped away from Recents.
     *
     * That gesture means "close this", so it is honoured rather than survived.
     * An app that stays connected after being dismissed from Recents is an app
     * the user cannot get rid of, and the notification would go on describing
     * connections whose Dart side is being torn down as this runs.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        onQuitRequested?.invoke()
        stopEverything()
        super.onTaskRemoved(rootIntent)
    }

    private fun stopEverything() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun startInForeground(status: String) {
        ensureChannel()
        val notification = build(status)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun notificationManager() =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    /**
     * Low importance on purpose: this notification is a status line, not an
     * event. It must be visible, because Android requires it and because an
     * app running unseen is worse, but it has no business making a sound.
     */
    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.connection_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.connection_channel_description)
            setShowBadge(false)
        }
        notificationManager().createNotificationChannel(channel)
    }

    private fun build(status: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val quit = PendingIntent.getService(
            this,
            1,
            Intent(this, ConnectionService::class.java).setAction(ACTION_QUIT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }

        return builder
            .setContentTitle(getString(R.string.app_name))
            .setContentText(status)
            // A silhouette drawn by `make icons`; Android keeps only its alpha.
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .addAction(
                Notification.Action.Builder(
                    null,
                    getString(R.string.quit),
                    quit,
                ).build(),
            )
            .build()
    }
}
