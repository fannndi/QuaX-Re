package com.teskann.quax

import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "browser_resolver"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "scanMediaFile") {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        MediaScannerConnection.scanFile(context, arrayOf(path), null) { _, _ ->
                            result.success(null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "Path is null", null)
                    }
                } else if (call.method == "getDefaultBrowser") {
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        data = Uri.parse("https://")
                    }
                    val resolveInfo = packageManager.resolveActivity(
                        intent,
                        PackageManager.MATCH_DEFAULT_ONLY
                    )
                    if (resolveInfo != null) {
                        result.success(resolveInfo.activityInfo.packageName)
                    } else {
                        result.success(null)
                    }
                } else if (call.method == "hasAllFilesAccess") {
                    result.success(hasAllFilesAccess())
                } else if (call.method == "requestAllFilesAccess") {
                    if (hasAllFilesAccess()) {
                        result.success(true)
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                            result.success(false)
                        } catch (e: Exception) {
                            val fallback = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                            startActivity(fallback)
                            result.success(false)
                        }
                    } else {
                        result.success(true) // pre-R: manifest runtime permission governs this
                    }
                }
            }
    }

    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true
        }
    }
}
