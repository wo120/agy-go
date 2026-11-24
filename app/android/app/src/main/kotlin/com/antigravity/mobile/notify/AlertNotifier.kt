package com.antigravity.mobile.notify

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import com.antigravity.mobile.MainActivity

/**
 * Posts high-priority lockscreen/heads-up alerts with Android RemoteInput inline replies
 * and quick-confirm action buttons.
 */
object AlertNotifier {
    const val CHANNEL_ALERTS = "agy_agent_alerts"
    const val KEY_DIRECT_REPLY = "agy_direct_reply_text"
    const val EXTRA_CONVERSATION_ID = "conversationId"
    const val EXTRA_NOTIFICATION_ID = "notificationId"
    const val EXTRA_QUICK_TEXT = "quickReplyText"
    const val ACTION_REPLY = "com.antigravity.mobile.ACTION_REPLY"
    const val ACTION_QUICK = "com.antigravity.mobile.ACTION_QUICK"

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ALERTS) != null) return
        val ch = NotificationChannel(
            CHANNEL_ALERTS,
            "Agent 任务提醒与决策确认",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "任务完成、子代理汇总或等待拍板确认时弹出提醒"
            enableVibration(true)
        }
        nm.createNotificationChannel(ch)
    }

    fun showAlert(
        context: Context,
        alertId: String,
        kind: String,
        conversationId: String,
        title: String,
        workspace: String,
        body: String,
        quickReplies: List<String>,
    ) {
        ensureChannels(context)
        val notifId = (conversationId.hashCode() and 0x7fffffff).coerceAtLeast(2000)

        val openIntent = Intent(context, MainActivity::class.java).apply {
            putExtra(EXTRA_CONVERSATION_ID, conversationId)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val contentPi = PendingIntent.getActivity(
            context,
            notifId,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val subText = if (workspace.isNotEmpty()) "Levity · $workspace" else "Levity for Antigravity"
        val builder = NotificationCompat.Builder(context, CHANNEL_ALERTS)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title.ifEmpty { "Levity for Antigravity" })
            .setSubText(subText)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setContentIntent(contentPi)

        // Inline RemoteInput direct reply right from lockscreen / shade
        val remoteInput = RemoteInput.Builder(KEY_DIRECT_REPLY)
            .setLabel("直接回复 Agent...")
            .build()
        val replyIntent = Intent(context, AlertActionReceiver::class.java).apply {
            action = ACTION_REPLY
            putExtra(EXTRA_CONVERSATION_ID, conversationId)
            putExtra(EXTRA_NOTIFICATION_ID, notifId)
        }
        val replyFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val replyPi = PendingIntent.getBroadcast(context, notifId + 1, replyIntent, replyFlags)
        builder.addAction(
            NotificationCompat.Action.Builder(
                android.R.drawable.ic_menu_send,
                "直接回复",
                replyPi,
            ).addRemoteInput(remoteInput).build(),
        )

        // Up to 2 quick-decision action buttons (e.g. "确认，直接开工")
        quickReplies.take(2).forEachIndexed { idx, label ->
            val quickIntent = Intent(context, AlertActionReceiver::class.java).apply {
                action = ACTION_QUICK
                putExtra(EXTRA_CONVERSATION_ID, conversationId)
                putExtra(EXTRA_NOTIFICATION_ID, notifId)
                putExtra(EXTRA_QUICK_TEXT, label)
            }
            val quickPi = PendingIntent.getBroadcast(
                context,
                notifId + 10 + idx,
                quickIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(
                NotificationCompat.Action.Builder(
                    android.R.drawable.ic_menu_agenda,
                    label,
                    quickPi,
                ).build(),
            )
        }

        try {
            NotificationManagerCompat.from(context).notify(notifId, builder.build())
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS not yet granted on Android 13+
        }
    }

    fun markReplied(context: Context, notifId: Int, replyText: String) {
        val updated = NotificationCompat.Builder(context, CHANNEL_ALERTS)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("已发送给 Mac 端 Antigravity ✓")
            .setContentText(replyText)
            .setSilent(true)
            .setAutoCancel(true)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(notifId, updated)
        } catch (_: SecurityException) {
        }
    }
}
