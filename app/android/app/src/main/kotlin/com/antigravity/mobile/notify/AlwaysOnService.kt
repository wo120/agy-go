package com.antigravity.mobile.notify

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
import androidx.core.app.NotificationCompat
import com.antigravity.mobile.MainActivity

/**
 * Low-noise foreground service that keeps the WebSocket bridge alive under aggressive
 * OEM battery managers (such as Xiaomi HyperOS).
 */
class AlwaysOnService : Service() {
    companion object {
        const val CHANNEL_ID = "agy_always_on"
        private const val NOTIFICATION_ID = 1001
        private const val EXTRA_HOST = "hostName"
        private const val EXTRA_STATUS = "statusText"

        fun start(context: Context, hostName: String, statusText: String) {
            val intent = Intent(context, AlwaysOnService::class.java).apply {
                putExtra(EXTRA_HOST, hostName)
                putExtra(EXTRA_STATUS, statusText)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {
                // Background start / container FGS restrictions (e.g. Android 12+, HarmonyOS container)
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, AlwaysOnService::class.java))
            } catch (_: Exception) {
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        val host = intent?.getStringExtra(EXTRA_HOST) ?: "Antigravity"
        val status = intent?.getStringExtra(EXTRA_STATUS) ?: "$host · 未连接"

        val openIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pi = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("AGY Go")
            .setContentText(status)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setContentIntent(pi)
            .build()

        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            START_STICKY
        } catch (_: Exception) {
            stopSelf()
            START_NOT_STICKY
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "后台保活连接",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持与 Mac 端 Antigravity 的实时直连通道"
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }
}
