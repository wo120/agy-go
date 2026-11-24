package com.antigravity.mobile.notify

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Coordinates Dart <-> Android MethodChannel ("agy/native") for foreground keep-alive
 * and direct-reply system notifications.
 */
object NativeBridgePlugin : MethodChannel.MethodCallHandler {
    private const val CHANNEL = "agy/native"
    private const val REQ_POST_NOTIFICATIONS = 4091

    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var activityRef: Activity? = null

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        activityRef = activity
        val ch = MethodChannel(messenger, CHANNEL)
        ch.setMethodCallHandler(this)
        channel = ch
        AlertNotifier.ensureChannels(activity.applicationContext)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val act = activityRef
        if (act == null) {
            result.error("NO_ACTIVITY", "Activity is not attached", null)
            return
        }
        val appCtx = act.applicationContext

        when (call.method) {
            "startAlwaysOnService" -> {
                val hostName = call.argument<String>("hostName") ?: "Antigravity"
                val statusText = call.argument<String>("statusText") ?: "已连接"
                AlwaysOnService.start(appCtx, hostName, statusText)
                result.success(true)
            }
            "stopAlwaysOnService" -> {
                AlwaysOnService.stop(appCtx)
                result.success(true)
            }
            "showAgentAlert" -> {
                val alertId = call.argument<String>("alertId") ?: ""
                val kind = call.argument<String>("kind") ?: "TASK_COMPLETED"
                val convId = call.argument<String>("conversationId") ?: ""
                val title = call.argument<String>("title") ?: "AGY Go"
                val workspace = call.argument<String>("workspace") ?: ""
                val body = call.argument<String>("body") ?: ""
                val quickReplies = call.argument<List<String>>("quickReplies") ?: emptyList()

                AlertNotifier.showAlert(
                    context = appCtx,
                    alertId = alertId,
                    kind = kind,
                    conversationId = convId,
                    title = title,
                    workspace = workspace,
                    body = body,
                    quickReplies = quickReplies,
                )
                result.success(true)
            }
            "requestPermissions" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val granted = ContextCompat.checkSelfPermission(
                        act,
                        Manifest.permission.POST_NOTIFICATIONS,
                    ) == PackageManager.PERMISSION_GRANTED
                    if (!granted) {
                        ActivityCompat.requestPermissions(
                            act,
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            REQ_POST_NOTIFICATIONS,
                        )
                    }
                }
                result.success(true)
            }
            "openBatterySettings" -> {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:${act.packageName}")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                try {
                    act.startActivity(intent)
                } catch (_: Exception) {
                    act.startActivity(
                        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        },
                    )
                }
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    fun dispatchNotificationReply(conversationId: String, text: String) {
        mainHandler.post {
            channel?.invokeMethod(
                "onNotificationReply",
                mapOf("conversationId" to conversationId, "text" to text),
            )
        }
    }

    fun dispatchNotificationTap(conversationId: String) {
        mainHandler.post {
            channel?.invokeMethod(
                "onNotificationTap",
                mapOf("conversationId" to conversationId),
            )
        }
    }
}
