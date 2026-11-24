package com.antigravity.mobile.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput

/**
 * Handles inline RemoteInput replies and quick-confirm button clicks directly from
 * Android lockscreen / notification shade without launching the UI.
 */
class AlertActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val convId = intent.getStringExtra(AlertNotifier.EXTRA_CONVERSATION_ID) ?: return
        val notifId = intent.getIntExtra(AlertNotifier.EXTRA_NOTIFICATION_ID, 0)

        val replyText = when (intent.action) {
            AlertNotifier.ACTION_REPLY -> {
                RemoteInput.getResultsFromIntent(intent)
                    ?.getCharSequence(AlertNotifier.KEY_DIRECT_REPLY)
                    ?.toString()
                    ?.trim()
            }
            AlertNotifier.ACTION_QUICK -> {
                intent.getStringExtra(AlertNotifier.EXTRA_QUICK_TEXT)?.trim()
            }
            else -> null
        }

        if (replyText.isNullOrEmpty()) return

        NativeBridgePlugin.dispatchNotificationReply(convId, replyText)
        if (notifId > 0) {
            AlertNotifier.markReplied(context.applicationContext, notifId, replyText)
        }
    }
}
