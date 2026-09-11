package com.teskann.quax

import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Bitmap.CompressFormat.PNG
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider

class MainActivity : FlutterActivity() {
    private val CHANNEL = "browser_resolver"
    private val mediaExtensions = setOf("mp4", "mov", "webm", "mkv", "m4v", "jpg", "jpeg", "png", "webp", "gif")

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
                } else if (call.method == "setGalleryVisibility") {
                    val dirPath = call.argument<String>("path")
                    val visible = call.argument<Boolean>("visible")
                    if (dirPath != null && visible != null) {
                        try {
                            val dir = File(dirPath)
                            if (!dir.exists()) {
                                result.error("INVALID_ARGUMENT", "Directory does not exist", null)
                            } else {
                                val nomedia = File(dir, ".nomedia")
                                if (visible) {
                                    nomedia.delete()
                                } else if (!nomedia.exists()) {
                                    nomedia.createNewFile()
                                }
                                // Rescan so the gallery adds or drops the files
                                // right away, without waiting for a reboot.
                                val media = dir.listFiles()?.filter {
                                    it.isFile && it.extension.lowercase() in mediaExtensions
                                }?.map { it.absolutePath }
                                if (!media.isNullOrEmpty()) {
                                    MediaScannerConnection.scanFile(context, media.toTypedArray(), null, null)
                                }
                                result.success(true)
                            }
                        } catch (e: IOException) {
                            result.error("VISIBILITY_FAILED", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "path or visible is null", null)
                    }
                } else if (call.method == "openMediaFile") {
                    val path = call.argument<String>("path")
                    val mime = call.argument<String>("mime") ?: "*/*"
                    if (path == null) {
                        result.error("INVALID_ARGUMENT", "path is null", null)
                    } else {
                        val file = File(path)
                        if (!file.exists()) {
                            result.error("NOT_FOUND", "File does not exist", null)
                        } else {
                            try {
                                val uri = FileProvider.getUriForFile(
                                    this, "$packageName.library", file
                                )
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, mime)
                                    addFlags(
                                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                                                or Intent.FLAG_ACTIVITY_NEW_TASK
                                    )
                                }
                                startActivity(Intent.createChooser(intent, null))
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("OPEN_FAILED", e.message, null)
                            }
                        }
                    }
                } else if (call.method == "videoThumbnail") {
                    val videoPath = call.argument<String>("path")
                    val outPath = call.argument<String>("outPath")
                    if (videoPath != null && outPath != null) {
                        var success: String? = null
                        try {
                            val retriever = MediaMetadataRetriever()
                            retriever.setDataSource(videoPath)
                            val frame = retriever.getFrameAtTime(1_000_000L) // one second in
                            retriever.release()
                            if (frame != null) {
                                File(outPath).parentFile?.mkdirs()
                                FileOutputStream(outPath).use { stream ->
                                    frame.compress(Bitmap.CompressFormat.JPEG, 70, stream)
                                }
                                frame.recycle()
                                success = outPath
                            }
                            result.success(success)
                        } catch (e: IOException) {
                            result.error("THUMBNAIL_FAILED", e.message, null)
                        } catch (e: RuntimeException) {
                            result.error("THUMBNAIL_FAILED", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "path is null", null)
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
