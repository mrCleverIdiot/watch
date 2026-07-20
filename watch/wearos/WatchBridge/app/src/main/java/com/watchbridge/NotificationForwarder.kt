package com.watchbridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/** Posts mirrored iPhone notifications (and incoming-call alerts) on the watch. */
class NotificationForwarder(private val context: Context) {

    companion object {
        const val CHANNEL_MIRRORED = "mirrored_notifications"
        const val CHANNEL_CALLS = "mirrored_calls"
    }

    private val nm = NotificationManagerCompat.from(context)

    init { ensureChannels() }

    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = context.getSystemService(NotificationManager::class.java)
        mgr.createNotificationChannel(
            NotificationChannel(CHANNEL_MIRRORED, "Phone notifications", NotificationManager.IMPORTANCE_HIGH)
        )
        mgr.createNotificationChannel(
            NotificationChannel(CHANNEL_CALLS, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
                setBypassDnd(true)
            }
        )
    }

    fun post(n: AncsNotification) {
        val title = n.title.ifBlank { n.appId.substringAfterLast('.') }
        val notif = NotificationCompat.Builder(context, CHANNEL_MIRRORED)
            .setSmallIcon(R.drawable.ic_stat_pulse)
            .setContentTitle(title)
            .setContentText(n.message)
            .setStyle(NotificationCompat.BigTextStyle().bigText(n.message))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        safeNotify(n.uid, notif)
    }

    fun postCall(n: AncsNotification) {
        val caller = n.title.ifBlank { n.message.ifBlank { "Incoming call" } }
        val builder = NotificationCompat.Builder(context, CHANNEL_CALLS)
            .setSmallIcon(R.drawable.ic_stat_pulse)
            .setContentTitle(caller)
            .setContentText("Incoming call")
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setOngoing(true)
            .setAutoCancel(false)

        if (n.negativeAction) {
            builder.addAction(0, "Decline", callAction(n.uid, AncsClient.ACTION_NEGATIVE))
        }
        if (n.positiveAction) {
            builder.addAction(0, "Answer", callAction(n.uid, AncsClient.ACTION_POSITIVE))
        }
        safeNotify(n.uid, builder.build())
    }

    fun cancel(uid: Int) = nm.cancel(uid)

    private fun callAction(uid: Int, actionId: Int): PendingIntent {
        val intent = Intent(context, CallActionReceiver::class.java).apply {
            action = CallActionReceiver.ACTION_CALL
            putExtra(CallActionReceiver.EXTRA_UID, uid)
            putExtra(CallActionReceiver.EXTRA_ACTION_ID, actionId)
        }
        // Unique request code per (uid, action) so the two buttons don't collide.
        val requestCode = uid * 2 + actionId
        return PendingIntent.getBroadcast(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun safeNotify(id: Int, notification: Notification) {
        if (!nm.areNotificationsEnabled()) {
            android.util.Log.w("NotificationForwarder", "POST_NOTIFICATIONS not granted — cannot show mirrored notification. Enable it in the watch's app settings.")
            return
        }
        try {
            nm.notify(id, notification)
            android.util.Log.d("NotificationForwarder", "Posted mirrored notification id=$id")
        } catch (e: SecurityException) {
            android.util.Log.w("NotificationForwarder", "notify() denied: ${e.message}")
        }
    }
}
