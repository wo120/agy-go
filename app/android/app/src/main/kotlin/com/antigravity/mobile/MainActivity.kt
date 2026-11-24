package com.antigravity.mobile

import android.content.Intent
import android.os.Bundle
import com.antigravity.mobile.notify.AlertNotifier
import com.antigravity.mobile.notify.NativeBridgePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NativeBridgePlugin.attach(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntentDeepLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntentDeepLink(intent)
    }

    private fun handleIntentDeepLink(intent: Intent?) {
        val convId = intent?.getStringExtra(AlertNotifier.EXTRA_CONVERSATION_ID)
        if (!convId.isNullOrEmpty()) {
            NativeBridgePlugin.dispatchNotificationTap(convId)
        }
    }
}
