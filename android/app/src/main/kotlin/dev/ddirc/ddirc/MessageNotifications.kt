package dev.ddirc.ddirc

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/**
 * Notifications about what somebody said.
 *
 * Kept apart from [ConnectionService]'s notification in every way that matters.
 * That one is a status line the platform charges us for staying alive, is
 * ongoing, and is deliberately silent. This one is an event, is dismissible,
 * and is the only thing in the app allowed to make a sound — so they get
 * separate channels, and silencing the price does not silence the point.
 *
 * What is *said* is decided in Dart and arrives finished. Nothing here inspects
 * a message or decides whether it was worth showing; by the time a call reaches
 * this class that has already been settled, next to the settings it depends on.
 */
object MessageNotifications {

    const val CHANNEL_ID = "messages"

    /** Which conversation a tapped notification was about. */
    const val EXTRA_PROFILE = "dev.ddirc.ddirc.extra.PROFILE"
    const val EXTRA_CONVERSATION = "dev.ddirc.ddirc.extra.CONVERSATION"

    /**
     * Stable ids, so a second message from the same person replaces the first
     * rather than stacking another copy of the same news.
     *
     * Derived from the key Dart already uses to identify a conversation, and
     * kept here so that cancelling one only needs that same key. `NOTIFICATION_ID`
     * in [ConnectionService] is 1, and a hash is astronomically unlikely to
     * collide with it — but it is masked away from small numbers regardless,
     * because "unlikely" is a poor reason to be able to cancel the foreground
     * notification by accident.
     */
    private fun idFor(key: String): Int = (key.hashCode() and 0x7fffffff) or 0x100

    fun show(
        context: Context,
        key: String,
        profileId: String,
        conversation: String,
        title: String,
        body: String,
    ) {
        ensureChannel(context)

        // FLAG_ACTIVITY_SINGLE_TOP so a running app is brought forward and told
        // where to go through onNewIntent, rather than started a second time on
        // top of itself.
        val open = PendingIntent.getActivity(
            context,
            idFor(key),
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_PROFILE, profileId)
                putExtra(EXTRA_CONVERSATION, conversation)
            },
            // Mutable would let another app rewrite where this leads. The extras
            // are decided here and must arrive as they left.
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = Notification.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            // The same silhouette the connection notification uses; Android
            // keeps only its alpha.
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .build()

        manager(context).notify(idFor(key), notification)
    }

    /** Take one away, because the conversation has been read somewhere else. */
    fun clear(context: Context, key: String) {
        manager(context).cancel(idFor(key))
    }

    /**
     * High importance, unlike the connection channel.
     *
     * This is an event addressed to the person holding the phone, which is the
     * case Android's own guidance reserves this for. The user can still turn it
     * down in system settings, and that is the right place for that decision —
     * what would be wrong is deciding it for them by filing a message under the
     * same quiet channel as a status line.
     */
    private fun ensureChannel(context: Context) {
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.message_channel_name),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = context.getString(R.string.message_channel_description)
            setShowBadge(true)
        }
        manager(context).createNotificationChannel(channel)
    }

    private fun manager(context: Context) =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
}
