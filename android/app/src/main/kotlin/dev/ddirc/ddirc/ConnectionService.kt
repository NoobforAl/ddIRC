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
import android.util.Log

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
 * out of the reaper's way, and it forwards one decision back to Dart, which is
 * where every decision in this app already lives.
 *
 * While it is up it is also the reason the Flutter engine outlives any window —
 * see [MainActivity.onDestroy]. The two facts are the same fact: this service
 * running *is* the user having asked for the app to go on without a window.
 */
class ConnectionService : Service() {

    companion object {
        /** The channel is the user's control over this: they can silence it. */
        const val CHANNEL_ID = "connection"
        private const val NOTIFICATION_ID = 1

        private const val TAG = "ddIRC"

        const val ACTION_START = "dev.ddirc.ddirc.action.START"
        const val ACTION_UPDATE = "dev.ddirc.ddirc.action.UPDATE"
        const val ACTION_STOP = "dev.ddirc.ddirc.action.STOP"

        /** The notification's own button. */
        const val ACTION_QUIT = "dev.ddirc.ddirc.action.QUIT"

        const val EXTRA_STATUS = "status"

        /**
         * Whether this is up.
         *
         * Read by [MainActivity] to decide whether the app ends with its
         * window, and by [AppEngine] to decide how to reach this. Kept here
         * rather than asked of `ActivityManager`, whose answer to the same
         * question is a list of every running service in the app and is
         * deprecated for exactly this use.
         */
        @Volatile
        var isRunning: Boolean = false
            private set
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A null intent is Android putting this back after killing the process
        // for memory — see the return below. Nothing survived it.
        if (intent == null) {
            restart()
            return START_STICKY
        }

        when (intent.action) {
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
            ACTION_QUIT -> if (!AppEngine.askToQuit()) stopEverything()
        }

        // Restarted with a null intent if the process is killed while this is
        // running — which it can only be while the user has asked ddIRC to stay
        // connected, because that is the only thing that starts it. Coming back
        // is the rest of that promise: the alternative is a client that quietly
        // stopped receiving hours ago and never said so. A service stopped on
        // purpose is not restarted, which is what makes Quit mean Quit.
        return START_STICKY
    }

    /**
     * The app was swiped away from Recents.
     *
     * Nothing happens here, deliberately, and this override exists to say so to
     * whoever comes looking for it. The gesture dismisses the window; it is not
     * a decision about the connections, and reading it as one is what used to
     * make "stay connected in the background" stop being true the moment
     * somebody tidied their Recents. Quit on the notification is the way out,
     * and it is on the notification precisely so that there is always one.
     *
     * The activity does end here. The engine does not — see
     * [MainActivity.onDestroy], which finds this service running and leaves it
     * alone.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
    }

    /**
     * Android has restarted this after taking the process for memory.
     *
     * Nothing came back with it — the engine, the Dart isolate and every
     * connection went with the process — so this is a cold start that already
     * owes a notification. The notification comes first, because it is what
     * buys the right to be running at all and Android is timing it. Dart
     * follows, and reconnects whatever was set to connect at launch, which is
     * as much as anything can honestly be restored from nothing.
     */
    private fun restart() {
        try {
            startInForeground(getString(R.string.reconnecting))
        } catch (e: IllegalStateException) {
            // Android 12 and later can refuse a foreground service started from
            // the background. There is nothing useful left to be without one: a
            // plain service in a cached process is the thing this exists to
            // avoid being.
            Log.w(TAG, "not allowed back into the foreground", e)
            stopSelf()
            return
        }
        AppEngine.warm(this)
    }

    private fun stopEverything() {
        isRunning = false
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
        // Last, so that a start Android refuses is not recorded as one that
        // happened. [restart] depends on that throwing.
        isRunning = true
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
