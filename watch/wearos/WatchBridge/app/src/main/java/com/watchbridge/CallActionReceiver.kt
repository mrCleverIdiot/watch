package com.watchbridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** Handles Answer/Decline taps on the mirrored incoming-call notification. */
class CallActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_CALL = "com.watchbridge.CALL_ACTION"
        const val EXTRA_UID = "uid"
        const val EXTRA_ACTION_ID = "actionId"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_CALL) return
        val uid = intent.getIntExtra(EXTRA_UID, -1)
        val actionId = intent.getIntExtra(EXTRA_ACTION_ID, -1)
        if (uid < 0 || actionId < 0) return
        Log.d("CallActionReceiver", "Call action uid=$uid action=$actionId")
        // Relay to the iPhone via ANCS, then clear the alert.
        BLEManager.getInstance(context).performAncsAction(uid, actionId)
        NotificationForwarder(context).cancel(uid)
    }
}
