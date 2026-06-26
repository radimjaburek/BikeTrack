package com.example.bike_track

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "com.example.bike_track/health_settings"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openHCPermissions" -> {
                        val attempts = listOf(
                            {
                                val i = Intent("androidx.health.ACTION_MANAGE_HEALTH_PERMISSIONS")
                                i.putExtra("android.intent.extra.PACKAGE_NAME", packageName)
                                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(i)
                            },
                            {
                                val i = packageManager.getLaunchIntentForPackage("com.google.android.apps.healthdata")
                                    ?: throw Exception("HC not found")
                                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(i)
                            },
                            {
                                val i = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                i.data = android.net.Uri.parse("package:$packageName")
                                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(i)
                            }
                        )
                        var launched = false
                        for (attempt in attempts) {
                            try { attempt(); launched = true; break } catch (_: Exception) {}
                        }
                        if (launched) result.success(null)
                        else result.error("LAUNCH_FAILED", "No handler found", null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
